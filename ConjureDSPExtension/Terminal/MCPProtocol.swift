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
        /// Optional: JSON-RPC notifications (per the 2.0 spec) omit `id` and
        /// expect NO reply. Codex's streamable-HTTP client sends
        /// `notifications/initialized` this way after initialize. If the field
        /// were non-optional, decoding would throw "parse error" and the
        /// client would see its transport channel close.
        let id: JSONRPCId?
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
            description: "Compile and load a DSP script into the audio engine WITHOUT touching the bundle on disk. Use for iterative script edits on an already-saved preset, or to try out scratchpad code before committing to a preset. For Python scripts, loads instantly. For Rust scripts, compiles to WASM first (takes a few seconds). Returns success + benchmark timing. CAUTION: compile_and_run does NOT write to the current preset's entry script — the bundle on disk stays whatever was last written via save_preset or write_bundle_file. If you want to create a new preset FROM a script, call `save_preset(name, source=…)` directly — that's atomic (writes bundle + loads kernel in one call), so you don't need compile_and_run afterward.",
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
            description: "Create (or re-save) a user preset bundle (.cdp directory). ATOMIC: in a single call, save_preset writes the bundle to disk, switches the plugin's currentPreset to it, AND loads the script into the kernel — you don't need a separate compile_and_run after (response reports `kernel_reloaded: true`). Always produces a fresh bundle — nothing is auto-copied from whatever preset was previously loaded. If you want the new bundle to inherit a UI, assets, or params from another preset (factory or user), call read_bundle_file on that preset FIRST, then call save_preset, then write_bundle_file to drop the inherited content into the new bundle. That keeps disk state consistent with the new source. Response returns `switched_current_preset: true` and `kernel_reloaded: true/false`.",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "name": PropertySchema(type: "string", description: "Name for the preset. If a user bundle with this name already exists, save_preset re-saves into it (entry script overwritten, existing ui/ + manifest preserved)."),
                    "source": PropertySchema(type: "string", description: "The DSP script text for the preset. Required when starting from scratchpad (no current preset) or when you're authoring new content. Optional — if omitted, save_preset uses whatever script the kernel currently has loaded."),
                    "language": PropertySchema(type: "string", description: "\"python\" or \"rust\". Optional — when omitted, auto-detected from the `source` text (def process = python, fn process / use conjuredsp = rust), or falls back to the kernel's current language."),
                    "scaffold_ui": PropertySchema(type: "boolean", description: "When true, creates a starter ui/index.html + declares the ui block in manifest.json so the preset renders with the custom-UI WebView from the start. Default: false (stock slider panel)."),
                ],
                required: ["name"]
            )
        ),
        ToolDefinition(
            name: "get_bundle_info",
            description: "Introspect the currently-loaded preset bundle. Returns the bundle's name and root path, whether it ships a custom HTML/JS UI, the manifest's UI block (width/height/fps/audioFrames), every editable text file inside (path + kind), AND a `user_visible_state` block describing what the user is actually seeing right now: `is_modified` (host shows '*' on title bar), `kernel_in_sync` (kernel-loaded script matches the on-disk entry script — false means audio is running stale code), `custom_ui_visible` (only when has_custom_ui; false means the user has toggled it off and is looking at the stock slider panel), and `issues[]` — a human-readable list, empty when everything's coherent. Use before reporting 'done' to the user: a green validate_bundle + smoke_test_ui can still ship over a stale kernel or a hidden custom UI. Returns bundle=null when the active preset is legacy single-file (pre-bundle).",
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
            description: "Write a text file inside the current preset bundle. Use to author the custom HTML/JS UI: set manifest.json's 'ui' block, write ui/index.html, add ui/assets/style.css. The plugin's file watcher picks up the change and hot-reloads the custom UI within ~300ms. Writes are REJECTED for factory presets (read-only resources in the app bundle) — if you're on a factory preset, call save_preset FIRST with a new name to create a writable user bundle, then write_bundle_file into that. Same applies to scratchpad state (no current preset). If you want the new bundle to inherit files from another preset, read_bundle_file them before save_preset and write them into the new bundle afterwards. The DSP script itself (manifest.entry) is writable but the DAW won't pick up the new code until compile_and_run runs it — for DSP edits, prefer compile_and_run which also re-loads the kernel. When the write touches ui/ or manifest.json, the response includes a `validation` block (same shape as validate_bundle) so you see unresolved param= refs, CSP violations, missing ui blocks, low text contrast, etc. on the same turn — inspect it before moving on. For runtime failures that static validation can't see (JS errors, custom elements that fail to upgrade, param bindings that silently don't resolve at runtime), follow up with `smoke_test_ui` before claiming done.",
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
            name: "validate_bundle",
            description: "Run a static validator over the currently-loaded bundle's manifest.json + ui/index.html. Catches unresolved param= references, CSP-blocked external fetches, missing manifest.ui block, Canvas 2D using CSS system colors it can't parse, and UIs that declare parameters but expose zero controls. Returns {status: \"pass\"|\"warn\"|\"fail\", issues: [{severity, check, file?, message, suggestion?}]}. write_bundle_file runs the same validator automatically on ui/ or manifest.json edits and inlines the report in its response, so you only need this tool for an explicit re-check or to validate without writing.",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "smoke_test_ui",
            description: "RUNTIME smoke test for the current bundle's custom UI. Loads ui/index.html in an offscreen WKWebView with the same scheme handler + bridge + cdp-ui.js injection the live plugin uses, then reports (1) whether window.ConjureDSP.ready fired within 3s, (2) every JavaScript error / unhandledrejection / console.error captured during load, (3) per-component binding state for every <cdp-slider> / <cdp-toggle> / <cdp-choice> / <cdp-xy> / <cdp-knob> — did it actually resolve its `param=` attribute at runtime, or is it silently inert? and (4) per-declared-parameter coverage (does every AU parameter have at least one working UI control?). Use this AFTER write_bundle_file to confirm the edits produce a working UI — static validation (validate_bundle) can't see JS errors that only manifest at runtime, custom elements that failed to upgrade, or parameter bindings broken by subtle name mismatches that slip past loose matching. Returns {status: \"pass\"|\"warn\"|\"fail\", ready_fired, ready_time_ms, js_errors[], components[], params[]}.",
            inputSchema: InputSchema(type: "object", properties: [:], required: nil)
        ),
        ToolDefinition(
            name: "get_docs",
            description: "Get detailed API reference for the conjuredsp library. Use this when you need exact method signatures, parameter types, default values, or usage details beyond what's in your system prompt. The \"ui\" topic documents the cdp-ui component library (cdp-slider, cdp-toggle, cdp-choice, cdp-xy, cdp-knob, cdp-panel) and the window.ConjureDSP bridge — call it before authoring any ui/index.html.",
            inputSchema: InputSchema(
                type: "object",
                properties: [
                    "topic": PropertySchema(type: "string", description: "Documentation topic: \"params\", \"filters\", \"delays\", \"oscillators\", \"utilities\", \"accel\", \"nam\", \"ui\", or \"all\".")
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
        case let num as NSNumber:
            // NSNumber bridges Bool and Int indistinguishably via Swift's `as`
            // pattern, so a plain `case let b as Bool` would match NSNumber(0)
            // as `false` and NSNumber(1) as `true`. Round-trips through
            // `JSONSerialization.jsonObject(with:)` produce NSNumber, so this
            // path is hit for the encoded-then-reparsed tool schemas.
            // Distinguish actual Bool via CFBooleanGetTypeID — only the two
            // kCFBoolean singletons match it.
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                try container.encode(num.boolValue)
            } else {
                let objcType = String(cString: num.objCType)
                // "f" = float, "d" = double
                if objcType == "f" || objcType == "d" {
                    try container.encode(num.doubleValue)
                } else {
                    try container.encode(num.int64Value)
                }
            }
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
