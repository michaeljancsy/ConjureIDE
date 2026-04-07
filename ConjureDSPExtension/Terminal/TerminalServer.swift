//
//  TerminalServer.swift
//  ConjureDSPExtension
//
//  Manages the MCP server (in-process, direct AU access). The PTY and
//  WebSocket relay run in the separate ConjureDSPTerminal companion app.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "TerminalServer")

/// Manages the MCP server. The terminal relay runs in ConjureDSPTerminal.app.
@MainActor
final class TerminalServer {

    let mcpServer: MCPServer
    private let appGroupContainerURL: URL?
    private var heartbeatTask: Task<Void, Never>?

    init(appGroupContainerURL: URL?) {
        self.appGroupContainerURL = appGroupContainerURL
        self.mcpServer = MCPServer(appGroupContainerURL: appGroupContainerURL)
    }

    // MARK: - Lifecycle

    /// Start the MCP server and signal readiness to the companion app.
    func start() {
        // Clean up any stale shutdown signal from a previous session
        deleteAppGroupFile("terminal-shutdown")

        mcpServer.start()

        // Wait for port assignment then write to App Group
        Task { @MainActor in
            for _ in 0..<40 {
                if let port = mcpServer.port, port > 0 {
                    writeMCPPortToAppGroup()
                    log.info("MCP server ready on port \(port)")
                    self.startHeartbeat()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            log.error("MCP server did not start within 10 seconds")
            SentryHelper.capture("MCP server did not start within 10 seconds", level: .error, category: "mcp")
        }
    }

    /// Stop the MCP server, clean up port file, and signal the companion app to reset.
    /// Nonisolated so it can be called from deinit.
    nonisolated func stop() {
        // File operations are safe from any thread
        deleteAppGroupFile("mcp-server-port")
        writeAppGroupFile("terminal-shutdown", content: "\(ProcessInfo.processInfo.processIdentifier)")

        // MCP server stop and heartbeat cancel must happen on main actor
        Task { @MainActor [mcpServer, weak self] in
            self?.heartbeatTask?.cancel()
            self?.heartbeatTask = nil
            mcpServer.stop()
        }

        log.info("Terminal server stopped — shutdown signal written")
    }

    /// Periodically re-write the MCP port file so the daemon can rediscover
    /// the extension if the file gets deleted (e.g., after health check failures).
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, let port = self.mcpServer.port else { break }
                self.writeMCPPortToAppGroup()
            }
        }
    }

    // MARK: - App Group helpers

    nonisolated private func appGroupURL() -> URL? {
        appGroupContainerURL
    }

    private func writeMCPPortToAppGroup() {
        guard let port = mcpServer.port else { return }
        writeAppGroupFile("mcp-server-port", content: "\(port)")
    }

    nonisolated private func writeAppGroupFile(_ name: String, content: String) {
        guard let url = appGroupURL() else {
            log.warning("Failed to get App Group container URL")
            return
        }
        let file = url.appendingPathComponent(name)
        do {
            try content.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            log.warning("Failed to write \(name): \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private func deleteAppGroupFile(_ name: String) {
        guard let url = appGroupURL() else { return }
        let file = url.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: file)
    }
}
