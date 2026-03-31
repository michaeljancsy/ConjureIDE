//
//  DaemonStatusCheckerTests.swift
//  ConjureDSPTests
//
//  Unit tests for DaemonStatusChecker — validates port file detection logic
//  and polling behavior for the terminal daemon launch prompt feature.
//

import Testing
import Darwin
import Foundation
import Network

@Suite(.serialized)
struct DaemonStatusCheckerTests {

    // MARK: - Port File Detection

    @Test("Returns false when port file does not exist")
    @MainActor
    func noPortFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let checker = DaemonStatusChecker()
        checker.portFileDirectoryOverride = tempDir

        #expect(checker.checkPortFile() == false)
    }

    @Test("Returns false when port file is empty")
    @MainActor
    func emptyPortFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let portFile = tempDir.appendingPathComponent("terminal-server-port")
        try "".write(to: portFile, atomically: true, encoding: .utf8)

        let checker = DaemonStatusChecker()
        checker.portFileDirectoryOverride = tempDir

        #expect(checker.checkPortFile() == false)
    }

    @Test("Returns false when port file contains zero")
    @MainActor
    func zeroPort() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let portFile = tempDir.appendingPathComponent("terminal-server-port")
        try "0".write(to: portFile, atomically: true, encoding: .utf8)

        let checker = DaemonStatusChecker()
        checker.portFileDirectoryOverride = tempDir

        #expect(checker.checkPortFile() == false)
    }

    @Test("Returns false when port file contains non-numeric text")
    @MainActor
    func nonNumericPort() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let portFile = tempDir.appendingPathComponent("terminal-server-port")
        try "not-a-port".write(to: portFile, atomically: true, encoding: .utf8)

        let checker = DaemonStatusChecker()
        checker.portFileDirectoryOverride = tempDir

        #expect(checker.checkPortFile() == false)
    }

    @Test("Returns true when port file contains valid port")
    @MainActor
    func validPort() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let portFile = tempDir.appendingPathComponent("terminal-server-port")
        try "8765".write(to: portFile, atomically: true, encoding: .utf8)

        let checker = DaemonStatusChecker()
        checker.portFileDirectoryOverride = tempDir

        #expect(checker.checkPortFile() == true)
    }

    @Test("Returns true when port file has trailing whitespace")
    @MainActor
    func portWithWhitespace() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let portFile = tempDir.appendingPathComponent("terminal-server-port")
        try "8765\n".write(to: portFile, atomically: true, encoding: .utf8)

        let checker = DaemonStatusChecker()
        checker.portFileDirectoryOverride = tempDir

        #expect(checker.checkPortFile() == true)
    }

    // MARK: - Polling (startChecking / stopChecking)

    @Test("startChecking sets isDaemonAvailable immediately from port file")
    @MainActor
    func startCheckingSetsInitialState() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let portFile = tempDir.appendingPathComponent("terminal-server-port")
        try "9999".write(to: portFile, atomically: true, encoding: .utf8)

        let checker = DaemonStatusChecker()
        checker.portFileDirectoryOverride = tempDir

        #expect(checker.isDaemonAvailable == false, "Should be false before startChecking")
        checker.startChecking()
        #expect(checker.isDaemonAvailable == true, "Should be true after startChecking with valid port file")
        checker.stopChecking()
    }

    @Test("startChecking sets false when no port file")
    @MainActor
    func startCheckingNoPortFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let checker = DaemonStatusChecker()
        checker.portFileDirectoryOverride = tempDir

        checker.startChecking()
        #expect(checker.isDaemonAvailable == false)
        checker.stopChecking()
    }

    @Test("Polling detects when daemon appears")
    @MainActor
    func pollingDetectsDaemonAppearing() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let checker = DaemonStatusChecker(pollInterval: 0.1)
        checker.portFileDirectoryOverride = tempDir

        checker.startChecking()
        #expect(checker.isDaemonAvailable == false)

        // Simulate daemon starting by writing port file
        let portFile = tempDir.appendingPathComponent("terminal-server-port")
        try "8765".write(to: portFile, atomically: true, encoding: .utf8)

        // Wait for polling to pick it up
        try await Task.sleep(for: .milliseconds(300))
        // Pump the run loop so the Timer fires
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        #expect(checker.isDaemonAvailable == true, "Polling should detect daemon appeared")
        checker.stopChecking()
    }

    @Test("Polling detects when daemon disappears")
    @MainActor
    func pollingDetectsDaemonDisappearing() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let portFile = tempDir.appendingPathComponent("terminal-server-port")
        try "8765".write(to: portFile, atomically: true, encoding: .utf8)

        let checker = DaemonStatusChecker(pollInterval: 0.1)
        checker.portFileDirectoryOverride = tempDir

        checker.startChecking()
        #expect(checker.isDaemonAvailable == true)

        // Simulate daemon stopping by removing port file
        try FileManager.default.removeItem(at: portFile)

        // Wait for polling to pick it up
        try await Task.sleep(for: .milliseconds(300))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        #expect(checker.isDaemonAvailable == false, "Polling should detect daemon disappeared")
        checker.stopChecking()
    }

    // MARK: - Connectivity Check (no portFileDirectoryOverride)

    @Test("Returns false when port file exists but nothing is listening (stale file)")
    @MainActor
    func stalePortFile() async throws {
        // Write a port file pointing to a port where nothing is listening.
        // Without portFileDirectoryOverride, the real connectivity check runs.
        // We use the actual App Group container here.
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.MichaelJancsy.ConjureDSP"
        )
        // Skip if App Group not available (e.g., CI without entitlements)
        try #require(container != nil, "App Group container not available")

        let portFile = container!.appendingPathComponent("terminal-server-port")
        // Back up existing file if present
        let backup = container!.appendingPathComponent("terminal-server-port.backup")
        let hadExistingFile = FileManager.default.fileExists(atPath: portFile.path)
        if hadExistingFile {
            try? FileManager.default.moveItem(at: portFile, to: backup)
        }
        defer {
            try? FileManager.default.removeItem(at: portFile)
            if hadExistingFile {
                try? FileManager.default.moveItem(at: backup, to: portFile)
            }
        }

        // Write a port where nothing is listening (use high ephemeral port)
        try "59999".write(to: portFile, atomically: true, encoding: .utf8)

        let checker = DaemonStatusChecker()
        // NOT setting portFileDirectoryOverride — real connectivity check runs
        #expect(checker.checkPortFile() == false,
                "Should return false when port file exists but daemon is not listening")
    }

    @Test("Returns true when port file exists and server is listening")
    @MainActor
    func liveServer() async throws {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.MichaelJancsy.ConjureDSP"
        )
        try #require(container != nil, "App Group container not available")

        // Start a real TCP listener on an ephemeral port using POSIX sockets
        let serverSock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(serverSock >= 0, "Failed to create socket")
        defer { Darwin.close(serverSock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // Let OS pick a port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bindResult == 0, "Failed to bind")
        try #require(Darwin.listen(serverSock, 1) == 0, "Failed to listen")

        // Get the assigned port
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverSock, $0, &boundLen)
            }
        }
        let listenerPort = UInt16(bigEndian: boundAddr.sin_port)
        try #require(listenerPort > 0)

        let portFile = container!.appendingPathComponent("terminal-server-port")
        let backup = container!.appendingPathComponent("terminal-server-port.backup")
        let hadExistingFile = FileManager.default.fileExists(atPath: portFile.path)
        if hadExistingFile {
            try? FileManager.default.moveItem(at: portFile, to: backup)
        }
        defer {
            try? FileManager.default.removeItem(at: portFile)
            if hadExistingFile {
                try? FileManager.default.moveItem(at: backup, to: portFile)
            }
        }

        try "\(listenerPort)".write(to: portFile, atomically: true, encoding: .utf8)

        let checker = DaemonStatusChecker()
        #expect(checker.checkPortFile() == true,
                "Should return true when daemon is actually listening")
    }

    @Test("stopChecking stops the timer")
    @MainActor
    func stopCheckingStopsTimer() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let checker = DaemonStatusChecker(pollInterval: 0.1)
        checker.portFileDirectoryOverride = tempDir

        checker.startChecking()
        #expect(checker.isDaemonAvailable == false)
        checker.stopChecking()

        // Write port file after stopping — should NOT be detected
        let portFile = tempDir.appendingPathComponent("terminal-server-port")
        try "8765".write(to: portFile, atomically: true, encoding: .utf8)

        try await Task.sleep(for: .milliseconds(300))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        #expect(checker.isDaemonAvailable == false, "Should not detect changes after stopChecking")
    }
}
