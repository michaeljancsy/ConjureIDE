//
//  TerminalServer.swift
//  ConjureDSPExtension
//
//  Manages the MCP server (in-process, direct AU access). The PTY and
//  WebSocket relay run in the separate ConjureDSPTerminal companion app.
//
//  Each AU instance gets a unique ID. The instance registers itself by
//  writing mcp-instances/{instanceID}.json to the App Group container.
//  The terminal app watches that directory and spins up a dedicated
//  PTY + WebSocket pair per instance.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "TerminalServer")

/// Manages the MCP server. The terminal relay runs in ConjureDSPTerminal.app.
@MainActor
final class TerminalServer {

    let mcpServer: MCPServer
    let instanceID: String
    private let appGroupContainerURL: URL?
    private var heartbeatTask: Task<Void, Never>?

    init(instanceID: String, appGroupContainerURL: URL?) {
        self.instanceID = instanceID
        self.appGroupContainerURL = appGroupContainerURL
        self.mcpServer = MCPServer(appGroupContainerURL: appGroupContainerURL)
    }

    // MARK: - Lifecycle

    /// Start the MCP server and register this instance for discovery.
    func start() {
        mcpServer.start()

        // Wait for port assignment then write instance file
        Task { @MainActor in
            for _ in 0..<40 {
                if let port = mcpServer.port, port > 0 {
                    writeInstanceFile()
                    log.info("MCP server ready on port \(port) (instance \(self.instanceID, privacy: .public))")
                    self.startHeartbeat()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            log.error("MCP server did not start within 10 seconds")
            SentryHelper.capture("MCP server did not start within 10 seconds", level: .error, category: "mcp")
        }
    }

    /// Stop the MCP server and remove this instance's registration file.
    /// Nonisolated so it can be called from deinit.
    nonisolated func stop() {
        // Remove instance file
        deleteInstanceFile()

        // MCP server stop and heartbeat cancel must happen on main actor
        Task { @MainActor [mcpServer, weak self] in
            self?.heartbeatTask?.cancel()
            self?.heartbeatTask = nil
            mcpServer.stop()
        }

        log.info("Terminal server stopped — instance \(self.instanceID, privacy: .public) deregistered")
    }

    /// Periodically re-write the instance file so the terminal app can
    /// rediscover this instance if the file gets deleted.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.mcpServer.port != nil else { break }
                self.writeInstanceFile()
            }
        }
    }

    // MARK: - Instance file helpers

    /// URL of the mcp-instances directory in the App Group container.
    nonisolated private func instancesDirectoryURL() -> URL? {
        guard let url = appGroupContainerURL else { return nil }
        return url.appendingPathComponent("mcp-instances")
    }

    /// URL of this instance's JSON file.
    nonisolated private func instanceFileURL() -> URL? {
        guard let dir = instancesDirectoryURL() else { return nil }
        return dir.appendingPathComponent("\(instanceID).json")
    }

    /// Write this instance's JSON registration file.
    /// Only writes when the file is missing or the mcpPort has changed,
    /// to avoid racing with the terminal app's wsPort writes.
    private func writeInstanceFile() {
        guard let port = mcpServer.port else { return }
        guard let fileURL = instanceFileURL(),
              let dirURL = instancesDirectoryURL() else {
            log.warning("Failed to get App Group container URL")
            return
        }

        // If the file already exists with the correct mcpPort, skip writing.
        // The heartbeat calls this periodically for recovery (file deleted),
        // but we must not overwrite the terminal app's wsPort field.
        if let existing = MCPInstanceInfo.read(from: fileURL),
           existing.mcpPort == port {
            return
        }

        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

            var info = MCPInstanceInfo(mcpPort: port)
            info.pid = Int32(ProcessInfo.processInfo.processIdentifier)
            info.createdAt = Date().timeIntervalSince1970
            try info.write(to: fileURL)
        } catch {
            log.warning("Failed to write instance file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Remove this instance's registration file.
    nonisolated private func deleteInstanceFile() {
        guard let fileURL = instanceFileURL() else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
