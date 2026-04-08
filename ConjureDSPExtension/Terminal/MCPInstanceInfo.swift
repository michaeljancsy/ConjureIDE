//
//  MCPInstanceInfo.swift
//  ConjureDSPExtension
//
//  Codable model for per-instance MCP discovery files.
//  Each AU extension instance writes its own JSON file to
//  mcp-instances/{uuid}.json in the App Group container.
//

import Foundation

struct MCPInstanceInfo: Codable {
    /// MCP server port — written by the AU extension.
    let mcpPort: UInt16

    /// WebSocket relay port — written back by the terminal app
    /// once it has started a dedicated PTY+WS pair for this instance.
    var wsPort: UInt16?

    /// AU extension process PID — used for stale-file detection.
    var pid: Int32?

    /// Unix timestamp of file creation.
    var createdAt: TimeInterval?

    /// Read an instance info file from disk.
    static func read(from url: URL) -> MCPInstanceInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MCPInstanceInfo.self, from: data)
    }

    /// Write this instance info to disk atomically.
    func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
