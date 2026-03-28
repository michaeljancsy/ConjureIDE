//
//  ConjureDSPTerminalApp.swift
//  ConjureDSPTerminal
//
//  Minimal companion app that runs the Claude Code terminal outside the
//  AU extension sandbox. The AU extension communicates with this app via
//  the App Group container for port discovery and lifecycle signaling.
//

import SwiftUI
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "TerminalApp")

@main
struct ConjureDSPTerminalApp: App {
    @State private var server = TerminalAppServer()

    var body: some Scene {
        WindowGroup {
            TerminalStatusView(server: server)
                .frame(width: 360, height: 200)
                .onAppear {
                    server.start()
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 200)
    }
}

// MARK: - Server

@MainActor
@Observable
class TerminalAppServer {
    private(set) var status: String = "Starting..."
    private(set) var isRunning = false
    private(set) var claudeState: String = "Idle"

    private var wsServer: WebSocketServer?
    private var pty: PTYManager?
    private var watchTask: Task<Void, Never>?

    private let appGroupID = "group.com.MichaelJancsy.ConjureDSP"

    func start() {
        log.info("ConjureDSP Terminal starting")
        status = "Waiting for ConjureDSP plugin..."
        startWatching()
    }

    // MARK: - App Group file watching

    /// Continuously watch for MCP port file (plugin started) and shutdown signal (plugin stopped).
    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Check for shutdown signal first
                if self.isRunning, self.shutdownSignalExists() {
                    log.info("Shutdown signal detected — resetting")
                    self.resetSession()
                    self.deleteAppGroupFile("terminal-shutdown")
                    self.status = "Waiting for ConjureDSP plugin..."
                    // Continue watching for next MCP port
                }

                // Check for MCP port (plugin started or restarted)
                if !self.isRunning, let port = self.readMCPPort() {
                    log.info("MCP port detected: \(port) — starting session")
                    self.startSession(mcpPort: port)
                }

                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Session lifecycle

    private func startSession(mcpPort: UInt16) {
        let ws = WebSocketServer()
        let p = PTYManager()
        self.wsServer = ws
        self.pty = p

        // Start WebSocket server
        let wsPort: UInt16 = 19836
        ws.start(port: wsPort)
        writeWebSocketPort(wsPort)

        // Configure PTY
        p.mcpServerPort = mcpPort

        p.onOutput = { [weak ws] data in
            ws?.broadcast(data)
        }

        ws.onClientInput = { [weak p] data in
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String, type == "resize",
               let cols = json["cols"] as? Int, let rows = json["rows"] as? Int {
                p?.resize(cols: UInt16(cols), rows: UInt16(rows))
            } else {
                p?.write(data)
            }
        }

        p.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .running:
                    self.claudeState = "Running"
                    self.wsServer?.broadcastText("\u{1b}[32m● Claude Code connected\u{1b}[0m\r\n")
                case .exited(let code):
                    self.claudeState = "Exited (code \(code))"
                    self.wsServer?.broadcastText("\r\n\u{1b}[33m● Claude Code exited (code \(code)).\u{1b}[0m\r\n")
                case .error(let msg):
                    self.claudeState = "Error: \(msg)"
                    self.wsServer?.broadcastText("\r\n\u{1b}[31m● Error: \(msg)\u{1b}[0m\r\n")
                case .idle:
                    self.claudeState = "Idle"
                }
            }
        }

        ws.onClientCountChange = { [weak p] count in
            if count > 0, let p, case .idle = p.state {
                p.start()
            }
        }

        isRunning = true
        status = "Ready (MCP: \(mcpPort), WS: \(wsPort))"
        log.info("Session started — MCP: \(mcpPort), WS: \(wsPort)")
    }

    private func resetSession() {
        // Stop PTY (kills Claude Code)
        pty?.stop()
        pty = nil

        // Stop WebSocket server
        wsServer?.stop()
        wsServer = nil

        isRunning = false
        claudeState = "Idle"
        log.info("Session reset")
    }

    // MARK: - App Group helpers

    private func appGroupURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private func readMCPPort() -> UInt16? {
        guard let url = appGroupURL() else { return nil }
        let portFile = url.appendingPathComponent("mcp-server-port")
        guard let s = try? String(contentsOf: portFile, encoding: .utf8),
              let port = UInt16(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0 else { return nil }
        return port
    }

    private func shutdownSignalExists() -> Bool {
        guard let url = appGroupURL() else { return false }
        let file = url.appendingPathComponent("terminal-shutdown")
        return FileManager.default.fileExists(atPath: file.path)
    }

    private func writeWebSocketPort(_ port: UInt16) {
        guard let url = appGroupURL() else { return }
        let portFile = url.appendingPathComponent("terminal-server-port")
        try? "\(port)".write(to: portFile, atomically: true, encoding: .utf8)
    }

    private func deleteAppGroupFile(_ name: String) {
        guard let url = appGroupURL() else { return }
        let file = url.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - UI

struct TerminalStatusView: View {
    let server: TerminalAppServer

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(server.isRunning ? .green : .secondary)

            Text("ConjureDSP Terminal")
                .font(.headline)

            Text(server.status)
                .font(.caption)
                .foregroundStyle(.secondary)

            if server.isRunning {
                HStack(spacing: 4) {
                    Circle()
                        .fill(server.claudeState == "Running" ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Text("Claude Code: \(server.claudeState)")
                        .font(.caption)
                }
            }
        }
        .padding(24)
    }
}
