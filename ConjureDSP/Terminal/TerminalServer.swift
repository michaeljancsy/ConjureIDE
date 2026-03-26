//
//  TerminalServer.swift
//  ConjureDSP
//
//  Orchestrates the MCP server, WebSocket server, and pty manager.
//  Manages the full lifecycle of the Claude Code terminal integration.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "TerminalServer")

/// Orchestrates MCP server + WebSocket relay + Claude Code pty.
@MainActor
final class TerminalServer {

    let mcpServer = MCPServer()
    let webSocketServer = WebSocketServer()
    let ptyManager = PTYManager()

    /// Whether Claude Code is currently running.
    var isClaudeRunning: Bool {
        if case .running = ptyManager.state { return true }
        return false
    }

    /// Number of connected terminal UI clients.
    var connectedClients: Int { webSocketServer.clientCount }

    /// The WebSocket port for terminal UI connections (written to App Group for extension discovery).
    var webSocketPort: UInt16? { webSocketServer.port }

    /// Called when terminal state changes (for UI updates).
    var onStateChange: (() -> Void)?

    // MARK: - Lifecycle

    /// Start all servers. Call after AU is loaded.
    func start() {
        // 1. Start MCP server (for Claude Code tool access)
        mcpServer.start()

        // 2. Start WebSocket server on a fixed port offset from MCP
        //    We use MCP port + 1 for the WebSocket, or pick a default
        let wsPort: UInt16 = 19836  // Fixed well-known port for ConjureDSP terminal
        webSocketServer.start(port: wsPort)

        // 3. Wire pty output → WebSocket broadcast
        ptyManager.onOutput = { [weak self] data in
            self?.webSocketServer.broadcast(data)
        }

        // 4. Wire WebSocket input → pty
        webSocketServer.onClientInput = { [weak self] data in
            self?.ptyManager.write(data)
        }

        // 5. Track state changes
        ptyManager.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.handlePTYStateChange(state)
            }
        }

        webSocketServer.onClientCountChange = { [weak self] count in
            self?.onStateChange?()
            // Auto-start Claude Code when first client connects
            if count > 0, case .idle = self?.ptyManager.state {
                self?.startClaudeCode()
            }
        }

        writeWebSocketPortToAppGroup()

        log.info("Terminal server started (MCP: \(self.mcpServer.port ?? 0), WS: \(wsPort))")
    }

    /// Stop everything.
    func stop() {
        ptyManager.stop()
        webSocketServer.stop()
        mcpServer.stop()
        log.info("Terminal server stopped")
    }

    /// Start or restart Claude Code in the pty.
    func startClaudeCode() {
        if case .running = ptyManager.state {
            return  // Already running
        }
        ptyManager.mcpServerPort = mcpServer.port
        ptyManager.start()
    }

    /// Stop Claude Code.
    func stopClaudeCode() {
        ptyManager.stop()
    }

    /// Restart Claude Code.
    func restartClaudeCode() {
        ptyManager.restart()
    }

    /// Resize the terminal.
    func resize(cols: UInt16, rows: UInt16) {
        ptyManager.resize(cols: cols, rows: rows)
    }

    // MARK: - Private

    private func handlePTYStateChange(_ state: PTYManager.State) {
        switch state {
        case .running:
            log.info("Claude Code started")
            // Notify connected terminal UIs
            webSocketServer.broadcastText("\u{1b}[32m● Claude Code connected\u{1b}[0m\r\n")
        case .exited(let code):
            log.info("Claude Code exited with code \(code)")
            webSocketServer.broadcastText("\r\n\u{1b}[33m● Claude Code exited (code \(code)). Press Enter to restart.\u{1b}[0m\r\n")
        case .error(let msg):
            log.error("Claude Code error: \(msg, privacy: .public)")
            webSocketServer.broadcastText("\r\n\u{1b}[31m● Error: \(msg)\u{1b}[0m\r\n")
        case .idle:
            break
        }
        onStateChange?()
    }

    private func writeWebSocketPortToAppGroup() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.MichaelJancsy.ConjureDSP") else {
            log.warning("Failed to get App Group container URL for WebSocket port")
            return
        }
        let portFileURL = containerURL.appendingPathComponent("terminal-server-port")
        do {
            try "19836".write(to: portFileURL, atomically: true, encoding: .utf8)
            log.info("Wrote WebSocket port to App Group container")
        } catch {
            log.warning("Failed to write WebSocket port: \(error.localizedDescription, privacy: .public)")
        }
    }
}
