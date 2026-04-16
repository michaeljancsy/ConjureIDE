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
        let instructions: String?
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
            description: "Get the current audio engine state: sample rate, channel count, max frames per buffer, bypass state, and algorithmic latency (samples + seconds).",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "list_presets",
            description: "List all available presets (factory and user). Returns preset names, whether they're factory or user presets, and their language (Python or Rust).",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "save_preset",
            description: "Save the currently loaded script as a user preset bundle (.cdp directory). Pass scaffold_ui=true to also drop in a starter ui/index.html that binds one slider per parameter — gives the user a working custom HTML/JS UI to build on.",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "name": PropertySchema(type: "string", description: "Name for the preset."),
                    "scaffold_ui": PropertySchema(type: "boolean", description: "When true, creates ui/index.html alongside the script so the preset ships with a custom HTML/JS UI. Default: false."),
                ],
                required: ["name"]
            )
        ),
        ToolDefinition(
            name: "get_bundle_info",
            description: "Introspect the currently-loaded preset bundle. Returns the bundle's name and root path, whether it ships a custom HTML/JS UI, the manifest's UI block (width/height/fps/audioFrames), and every editable text file inside (path + kind). Use before read_bundle_file / write_bundle_file to discover what's editable. Returns bundle=null when the active preset is legacy single-file (pre-bundle).",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "read_bundle_file",
            description: "Read any text file inside the current preset bundle — e.g. 'process.py', 'manifest.json', 'ui/index.html', 'ui/assets/style.css'. Relative paths only; absolute paths are rejected. Factory bundles are readable; user/repo bundles are also readable. Use get_bundle_info first to discover paths.",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "path": PropertySchema(type: "string", description: "Path relative to the bundle root (e.g. 'ui/index.html')."),
                ],
                required: ["path"]
            )
        ),
        ToolDefinition(
            name: "write_bundle_file",
            description: "Write a text file inside the current preset bundle. Use to author the custom HTML/JS UI: set manifest.json's 'ui' block, write ui/index.html, add ui/assets/style.css. The plugin's file watcher picks up the change and hot-reloads the custom UI within ~300ms. Writes are rejected for factory presets (read-only resources in the app bundle). The DSP script itself (manifest.entry) is writable but the DAW won't pick up the new code until compile_and_run runs it — for DSP edits, prefer compile_and_run which also re-loads the kernel.",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "path": PropertySchema(type: "string", description: "Path relative to the bundle root (e.g. 'ui/index.html')."),
                    "content": PropertySchema(type: "string", description: "UTF-8 text to write. Overwrites any existing file at that path. Parent directories are created automatically."),
                ],
                required: ["path", "content"]
            )
        ),
        ToolDefinition(
            name: "toggle_bypass",
            description: "Toggle bypass mode. When bypassed, audio passes through unprocessed (useful for A/B comparison).",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "get_docs",
            description: "Get detailed API reference for the conjuredsp library. Use this when you need exact method signatures, parameter types, default values, or usage details beyond what's in your system prompt.",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "topic": PropertySchema(type: "string", description: "Documentation topic: \"params\", \"filters\", \"delays\", \"oscillators\", \"utilities\", \"accel\", \"nam\", or \"all\".")
                ],
                required: ["topic"]
            )
        ),
        ToolDefinition(
            name: "list_packages",
            description: "List all packages available for import in DSP scripts. Returns Python packages (numpy, scipy, conjuredsp, plus user-installed) and Rust crates (conjuredsp built-in, plus user-installed via crate package manager). Call this to check what's available before writing a script.",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "list_tones",
            description: "List downloaded NAM tone models available for use in DSP scripts. Returns tone name, author, gear type, tags, makes, model variants, and the tone3000:// path to use with load_model(). Always call this before writing a NAM preset. If the user hasn't specified which tone to use, show them the available tones and ask which they prefer.",
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
