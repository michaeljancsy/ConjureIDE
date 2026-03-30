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

    let mcpServer = MCPServer()

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
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            log.error("MCP server did not start within 10 seconds")
        }
    }

    /// Stop the MCP server, clean up port file, and signal the companion app to reset.
    /// Nonisolated so it can be called from deinit.
    nonisolated func stop() {
        // File operations are safe from any thread
        deleteAppGroupFile("mcp-server-port")
        writeAppGroupFile("terminal-shutdown", content: "\(ProcessInfo.processInfo.processIdentifier)")

        // MCP server stop must happen on main actor
        Task { @MainActor [mcpServer] in
            mcpServer.stop()
        }

        log.info("Terminal server stopped — shutdown signal written")
    }

    // MARK: - App Group helpers

    nonisolated private func appGroupURL() -> URL? {
        AppGroupContainer.url
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
