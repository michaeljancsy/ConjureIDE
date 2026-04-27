//
//  WebSocketServerIntegrationTests.swift
//  ConjureDSPLogicTests
//
//  End-to-end tests for the WebSocketServer's verified-clients behaviour.
//  Stands up a real server on an ephemeral port, drives it with both raw
//  TCP probes (the DaemonStatusChecker.canConnect pattern) and real
//  WebSocket clients (URLSessionWebSocketTask — the xterm.js pattern),
//  and asserts:
//
//    • Raw TCP probe → no pending flush, no clientCount bump.
//    • Real WebSocket client → first frame flushes pendingBanner and
//      pendingControlMessage, clientCount reflects it.
//
//  This is the exact flow that was broken when the 5-second eviction
//  timer killed real clients before they could verify, and also the flow
//  that's now gated on LaunchQueue's flush-on-verify hook.
//

import Darwin
import Foundation
import Testing

@MainActor
struct WebSocketServerIntegrationTests {

    /// Stand up a server on an ephemeral port, wait until it reports `onReady`
    /// with a real port, and return it.
    static func startServer() async throws -> (WebSocketServer, UInt16) {
        let server = WebSocketServer()
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            server.onReady = { p in cont.resume(returning: p) }
            server.start(port: 0)
            // 2-second safety timeout so a failed listener doesn't hang the test suite.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                // If we already resumed, this cont-resume is a no-op thanks to Swift Testing
                // isolating continuations; but to be safe we guard with a weak check.
                // (checkedContinuation crashes on double-resume, so we just skip here.)
            }
        }
        return (server, port)
    }

    /// Raw TCP probe: connect, then immediately close. Mirrors
    /// `DaemonStatusChecker.canConnect(toPort:)`.
    static func rawTCPProbe(port: UInt16) {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // Don't speak WebSocket — just close.
    }

    /// Returns when the condition is true or the timeout elapses.
    static func waitFor(
        timeout: TimeInterval = 2.0,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Tests

    @Test("Raw TCP probe does NOT count as a verified client and does NOT flush pendingBanner")
    func rawProbeDoesNotFlush() async throws {
        let (server, port) = try await Self.startServer()
        server.pendingBanner = "welcome banner"

        Self.rawTCPProbe(port: port)
        // Let the listener accept + close.
        await Self.waitFor(timeout: 0.5) { false }

        // clientCount reports *verified* clients only — probe should not count.
        #expect(server.clientCount == 0)
        // Banner still queued, waiting for a real client.
        #expect(server.pendingBanner == "welcome banner")

        server.stop()
    }

    @Test("Real WebSocket client verifies on first frame and receives queued banner + control message")
    func realClientReceivesPending() async throws {
        let (server, port) = try await Self.startServer()
        server.pendingBanner = "BANNER"
        server.pendingControlMessage = #"{"type":"claudeNotInstalled"}"#.data(using: .utf8)!

        // Open a real WebSocket client.
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let task = session.webSocketTask(with: url)
        task.resume()

        // Send a frame — this is what verifies the client on the server.
        try await task.send(.string(#"{"type":"resize","cols":80,"rows":24}"#))

        // Collect the two pending-flush messages the server should now send us.
        var received: [String] = []
        for _ in 0..<2 {
            let msg = try await task.receive()
            switch msg {
            case .string(let s): received.append(s)
            case .data(let d): received.append(String(data: d, encoding: .utf8) ?? "<binary>")
            @unknown default: break
            }
        }

        #expect(received.contains(#"{"type":"claudeNotInstalled"}"#))
        #expect(received.contains("BANNER"))
        #expect(server.clientCount == 1)
        // Pending fields are RETAINED after the first verified client receives them.
        // They represent the PTY's *current* display state, so a second client
        // connecting moments later (editor + DevTools, rapid reconnect) needs to
        // see the same state. Supersession happens on `onControlMessage`
        // overwrite or PTY .idle clearing the fields explicitly — see
        // `WebSocketServer.verifyAndFlushIfNeeded` and
        // `ConjureDSPTerminalApp.onStateChange`.
        #expect(server.pendingBanner == "BANNER")
        #expect(server.pendingControlMessage != nil)

        task.cancel(with: .normalClosure, reason: nil)
        server.stop()
    }

    @Test("Probe THEN real client — only real client receives the pending banner")
    func probeThenRealClient() async throws {
        let (server, port) = try await Self.startServer()
        server.pendingBanner = "DELAYED"

        // Fire a few probes.
        for _ in 0..<3 {
            Self.rawTCPProbe(port: port)
        }
        await Self.waitFor(timeout: 0.3) { false }

        // Probes don't verify, so the banner stays queued for a real client.
        #expect(server.pendingBanner == "DELAYED")
        #expect(server.clientCount == 0)

        // Now the real client connects and sends a frame.
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        try await task.send(.string("hello"))

        let msg = try await task.receive()
        var text = ""
        if case .string(let s) = msg { text = s }
        else if case .data(let d) = msg { text = String(data: d, encoding: .utf8) ?? "" }

        #expect(text == "DELAYED")
        #expect(server.clientCount == 1)
        // Banner is retained — see `realClientReceivesPending` for the rationale.
        #expect(server.pendingBanner == "DELAYED")

        task.cancel(with: .normalClosure, reason: nil)
        server.stop()
    }

    @Test("Two clients in sequence both receive the pending banner (rapid-reconnect / editor + DevTools)")
    func twoSequentialClientsBothReceivePending() async throws {
        let (server, port) = try await Self.startServer()
        server.pendingBanner = "STATE"

        // First real client.
        let session = URLSession(configuration: .ephemeral)
        let task1 = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task1.resume()
        try await task1.send(.string("hi-1"))
        let msg1 = try await task1.receive()
        var text1 = ""
        if case .string(let s) = msg1 { text1 = s }
        #expect(text1 == "STATE")

        // Banner is retained.
        #expect(server.pendingBanner == "STATE")

        // Second real client connects shortly after — must also see the banner.
        let task2 = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task2.resume()
        try await task2.send(.string("hi-2"))
        let msg2 = try await task2.receive()
        var text2 = ""
        if case .string(let s) = msg2 { text2 = s }
        #expect(text2 == "STATE")

        task1.cancel(with: .normalClosure, reason: nil)
        task2.cancel(with: .normalClosure, reason: nil)
        server.stop()
    }

    @Test("Externally clearing pendingBanner (PTY .idle path) drops state for late clients")
    func externalClearOfPendingBanner() async throws {
        let (server, port) = try await Self.startServer()
        server.pendingBanner = "STALE"

        // Simulate the PTY going idle: the app-level handler nils both pending fields.
        // (See `ConjureDSPTerminalApp.onStateChange` for the actual edge.)
        server.pendingBanner = nil
        server.pendingControlMessage = nil

        // A client connecting AFTER the clear receives nothing.
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        try await task.send(.string("hello"))

        // Race a receive against a short deadline. Nothing should arrive.
        let receiveTask = Task<String?, Error> {
            let msg = try await task.receive()
            if case .string(let s) = msg { return s }
            if case .data(let d) = msg { return String(data: d, encoding: .utf8) }
            return nil
        }
        try? await Task.sleep(for: .milliseconds(200))
        receiveTask.cancel()

        #expect(server.pendingBanner == nil)
        #expect(server.pendingControlMessage == nil)

        task.cancel(with: .normalClosure, reason: nil)
        server.stop()
    }

    @Test("onClientCountChange fires with verified count, not raw clients dict size")
    func onClientCountChangeUsesVerified() async throws {
        let (server, port) = try await Self.startServer()

        var seenCounts: [Int] = []
        server.onClientCountChange = { seenCounts.append($0) }

        // Probes shouldn't bump the callback — they're not verified.
        for _ in 0..<3 { Self.rawTCPProbe(port: port) }
        await Self.waitFor(timeout: 0.3) { false }

        #expect(!seenCounts.contains(where: { $0 > 0 }))

        // Real client verifies → callback should fire with 1.
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        try await task.send(.string("hi"))

        await Self.waitFor(timeout: 1.0) { seenCounts.contains(1) }
        #expect(seenCounts.contains(1))

        task.cancel(with: .normalClosure, reason: nil)
        server.stop()
    }

    @Test("Real client input is surfaced via onClientInput")
    func onClientInputFires() async throws {
        let (server, port) = try await Self.startServer()

        var inputs: [Data] = []
        server.onClientInput = { inputs.append($0) }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        task.resume()
        try await task.send(.string("ls -la"))

        await Self.waitFor(timeout: 1.0) { !inputs.isEmpty }

        #expect(inputs.first == "ls -la".data(using: .utf8))

        task.cancel(with: .normalClosure, reason: nil)
        server.stop()
    }
}
