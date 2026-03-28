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
    private var currentMCPPort: UInt16 = 0
    private var healthCheckFailCount = 0
    private let healthCheckThreshold = 3  // consecutive failures before reset

    private let appGroupID = "group.com.MichaelJancsy.ConjureDSP"

    func start() {
        log.info("ConjureDSP Terminal starting")
        status = "Waiting for ConjureDSP plugin..."
        startWatching()
    }

    // MARK: - App Group file watching

    /// Continuously watch for lifecycle changes via three mechanisms:
    /// 1. Shutdown signal — clean AU teardown (deinit wrote the file)
    /// 2. Port change — AU restarted, new MCP server on a different port
    /// 3. Health check — MCP server stopped responding (AU crashed or closed without signal)
    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            var tickCount = 0
            while !Task.isCancelled {
                guard let self else { return }

                // 1. Shutdown signal (fastest detection — file written by AU deinit)
                if self.isRunning, self.shutdownSignalExists() {
                    log.info("Shutdown signal detected — resetting")
                    self.resetSession()
                    self.deleteAppGroupFile("terminal-shutdown")
                    self.status = "Waiting for ConjureDSP plugin..."
                }

                // 2. Port change or new port
                if let port = self.readMCPPort() {
                    if !self.isRunning {
                        log.info("MCP port detected: \(port) — starting session")
                        self.startSession(mcpPort: port)
                    } else if port != self.currentMCPPort {
                        log.info("MCP port changed \(self.currentMCPPort) → \(port) — restarting session")
                        self.resetSession()
                        self.startSession(mcpPort: port)
                    }
                }

                // 3. Health check (every ~3 seconds when running)
                if self.isRunning, tickCount % 6 == 0 {
                    let healthy = await self.checkMCPHealth()
                    if healthy {
                        self.healthCheckFailCount = 0
                    } else {
                        self.healthCheckFailCount += 1
                        if self.healthCheckFailCount >= self.healthCheckThreshold {
                            log.info("MCP server unreachable after \(self.healthCheckFailCount) checks — resetting")
                            self.resetSession()
                            self.deleteAppGroupFile("mcp-server-port")
                            self.status = "Waiting for ConjureDSP plugin..."
                        }
                    }
                }

                tickCount += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Ping the MCP server's health endpoint.
    private func checkMCPHealth() async -> Bool {
        guard currentMCPPort > 0,
              let url = URL(string: "http://localhost:\(currentMCPPort)/health") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            // Verify it's actually our server
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String, status == "ok" {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Session lifecycle

    private func startSession(mcpPort: UInt16) {
        let ws = WebSocketServer()
        let p = PTYManager()
        self.wsServer = ws
        self.pty = p

        // Start WebSocket server — write port file only after listener confirms ready
        let wsPort: UInt16 = 19836
        ws.onReady = { [weak self] confirmedPort in
            self?.writeWebSocketPort(confirmedPort)
        }
        ws.start(port: wsPort)

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
            guard let p else { return }
            if count > 0 {
                if case .idle = p.state {
                    p.start()
                } else if case .running = p.state {
                    // New client connected to an already-running PTY — send SIGWINCH
                    // to make Claude Code redraw its screen for the fresh xterm.js
                    p.sendSIGWINCH()
                }
            }
        }

        currentMCPPort = mcpPort
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

        currentMCPPort = 0
        healthCheckFailCount = 0
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
