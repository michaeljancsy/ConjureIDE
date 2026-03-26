//
//  MCPProtocol.swift
//  ConjureDSP
//
//  MCP (Model Context Protocol) JSON-RPC types and tool definitions.
//

import Foundation

// MARK: - JSON-RPC 2.0

enum MCPProtocol {

    // MARK: - Request / Response

    struct JSONRPCRequest: Codable {
        let jsonrpc: String  // "2.0"
        let id: JSONRPCId
        let method: String
        let params: [String: AnyCodable]?
    }

    struct JSONRPCResponse: Encodable {
        let jsonrpc: String = "2.0"
        let id: JSONRPCId
        let result: AnyCodable?
        let error: JSONRPCError?
    }

    struct JSONRPCNotification: Codable {
        let jsonrpc: String  // "2.0"
        let method: String
        let params: [String: AnyCodable]?
    }

    struct JSONRPCError: Encodable {
        let code: Int
        let message: String
    }

    // MARK: - MCP Messages

    struct InitializeResult: Encodable {
        let protocolVersion: String = "2024-11-05"
        let capabilities: ServerCapabilities
        let serverInfo: ServerInfo
    }

    struct ServerCapabilities: Encodable {
        let tools: ToolsCapability?
    }

    struct ToolsCapability: Encodable {
        let listChanged: Bool?
    }

    struct ServerInfo: Encodable {
        let name: String
        let version: String
    }

    struct ToolsListResult: Encodable {
        let tools: [ToolDefinition]
    }

    struct ToolDefinition: Encodable {
        let name: String
        let description: String
        let inputSchema: InputSchema
    }

    struct InputSchema: Encodable {
        let type: String  // "object"
        let properties: [String: PropertySchema]
        let required: [String]?
    }

    struct PropertySchema: Encodable {
        let type: String
        let description: String
        let minimum: Int?
        let maximum: Int?

        init(type: String, description: String, minimum: Int? = nil, maximum: Int? = nil) {
            self.type = type
            self.description = description
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    struct ToolCallResult: Encodable {
        let content: [ContentBlock]
        let isError: Bool?
    }

    struct ContentBlock: Encodable {
        let type: String  // "text"
        let text: String
    }

    // MARK: - Tool Definitions

    static let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "compile_and_run",
            description: "Compile and load a DSP script into the audio engine. For Python scripts, this loads instantly. For Rust scripts, this compiles to WASM first (takes a few seconds). Returns whether it succeeded, any error message, and benchmark timing.",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "source": PropertySchema(type: "string", description: "The complete script source code (Python or Rust). Language is auto-detected.")
                ],
                required: ["source"]
            )
        ),
        ToolDefinition(
            name: "get_script",
            description: "Get the currently loaded script source code.",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "get_error",
            description: "Get the last error message from script loading or compilation.",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "set_parameter",
            description: "Set a DAW-automatable parameter value. Up to 16 parameters (indices 0-15). Pass the actual value in the parameter's declared range (e.g., 1000.0 for a cutoff in Hz). Use get_parameters first to see available parameters and their ranges.",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "index": PropertySchema(type: "integer", description: "Parameter index (0-15).", minimum: 0, maximum: 15),
                    "value": PropertySchema(type: "number", description: "Parameter value in the declared range (e.g., 1000.0 for Hz, -12.0 for dB).")
                ],
                required: ["index", "value"]
            )
        ),
        ToolDefinition(
            name: "get_parameters",
            description: "Read all active parameter values with names, ranges, and units.",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "get_audio_state",
            description: "Get the current audio engine state: sample rate, channel count, max frames per buffer, and bypass state.",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "list_presets",
            description: "List all available presets (factory and user). Returns preset names, whether they're factory or user presets, and their language (Python or Rust).",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "save_preset",
            description: "Save the currently loaded script as a user preset.",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "name": PropertySchema(type: "string", description: "Name for the preset.")
                ],
                required: ["name"]
            )
        ),
        ToolDefinition(
            name: "toggle_bypass",
            description: "Toggle bypass mode. When bypassed, audio passes through unprocessed (useful for A/B comparison).",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
    ]
}

// MARK: - JSON-RPC ID (can be string or int)

enum JSONRPCId: Codable, Equatable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.typeMismatch(JSONRPCId.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected string or int"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        }
    }
}

// MARK: - AnyCodable (for dynamic JSON values)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
