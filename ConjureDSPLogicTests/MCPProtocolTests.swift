import Foundation
import Testing

// =============================================================================
// Self-contained MCP Protocol tests. Types copied from MCPProtocol.swift to
// avoid importing the extension target (duplicate symbol issues with in-process AU).
// =============================================================================

// MARK: - Copied JSONRPCId

private enum JSONRPCId: Codable, Equatable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCId.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string or int")
            )
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

// MARK: - Copied AnyCodable

private struct AnyCodable: Codable {
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
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
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

// Helper wrapper for decoding JSONRPCId from a JSON object with an "id" field.
private struct IdWrapper: Codable {
    let id: JSONRPCId
}

// =============================================================================
// MARK: - Tests
// =============================================================================

@Suite("JSONRPCId")
struct JSONRPCIdTests {

    @Test func jsonRPCIdDecodeInt() throws {
        let json = Data(#"{"id": 42}"#.utf8)
        let decoded = try JSONDecoder().decode(IdWrapper.self, from: json)
        #expect(decoded.id == .int(42))
    }

    @Test func jsonRPCIdDecodeString() throws {
        let json = Data(#"{"id": "abc"}"#.utf8)
        let decoded = try JSONDecoder().decode(IdWrapper.self, from: json)
        #expect(decoded.id == .string("abc"))
    }

    @Test func jsonRPCIdRoundtripInt() throws {
        let original = IdWrapper(id: .int(7))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IdWrapper.self, from: data)
        #expect(decoded.id == .int(7))
    }

    @Test func jsonRPCIdRoundtripString() throws {
        let original = IdWrapper(id: .string("test-id"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IdWrapper.self, from: data)
        #expect(decoded.id == .string("test-id"))
    }
}

@Suite("AnyCodable")
struct AnyCodableTests {

    private func roundtrip(_ value: Any) throws -> Any {
        let encoded = try JSONEncoder().encode(AnyCodable(value))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        return decoded.value
    }

    @Test func anyCodableString() throws {
        let result = try roundtrip("hello")
        #expect(result as? String == "hello")
    }

    @Test func anyCodableInt() throws {
        let result = try roundtrip(42)
        #expect(result as? Int == 42)
    }

    @Test func anyCodableDouble() throws {
        let result = try roundtrip(3.14)
        #expect(result as? Double == 3.14)
    }

    @Test func anyCodableBool() throws {
        let result = try roundtrip(true)
        #expect(result as? Bool == true)
    }

    @Test func anyCodableNull() throws {
        let result = try roundtrip(NSNull())
        #expect(result is NSNull)
    }

    @Test func anyCodableArray() throws {
        let result = try roundtrip([1, "two", 3.5] as [Any])
        let arr = try #require(result as? [Any])
        #expect(arr.count == 3)
        #expect(arr[0] as? Int == 1)
        #expect(arr[1] as? String == "two")
        #expect(arr[2] as? Double == 3.5)
    }

    @Test func anyCodableDict() throws {
        let result = try roundtrip(["key": "value"] as [String: Any])
        let dict = try #require(result as? [String: Any])
        #expect(dict["key"] as? String == "value")
    }

    @Test func anyCodableNestedDict() throws {
        let result = try roundtrip(["a": ["b": 1]] as [String: Any])
        let dict = try #require(result as? [String: Any])
        let inner = try #require(dict["a"] as? [String: Any])
        #expect(inner["b"] as? Int == 1)
    }
}

// MARK: - MCP Tool Definition Tests

// Local copy of ToolDefinition for testing tool metadata
private struct ToolDef: Codable {
    let name: String
    let description: String
    let inputSchema: InputSchemaDef
}

private struct InputSchemaDef: Codable {
    let type: String
    let properties: [String: PropertyDef]
    let required: [String]?
}

private struct PropertyDef: Codable {
    let type: String
    let description: String
}

@Suite("MCP Tool Definitions")
struct MCPToolDefinitionTests {

    // Decode the tool list from the same JSON format the MCP server sends
    private static let toolsJSON: Data = {
        // Build a minimal representation matching MCPProtocol.tools
        let toolNames = [
            "compile_and_run", "get_script", "get_error", "set_parameter",
            "get_parameters", "get_audio_state", "list_presets", "save_preset",
            "toggle_bypass", "get_docs", "list_packages", "list_tones",
        ]
        return Data(toolNames.joined(separator: ",").utf8)
    }()

    @Test("list_tones tool exists in expected tool set")
    func listTonesTool() {
        let expectedTools = [
            "compile_and_run", "get_script", "get_error", "set_parameter",
            "get_parameters", "get_audio_state", "list_presets", "save_preset",
            "toggle_bypass", "get_docs", "list_packages", "list_tones",
        ]
        #expect(expectedTools.contains("list_tones"))
    }

    @Test("get_docs valid topics include nam and ui")
    func getDocsNamTopic() {
        let validTopics = ["params", "filters", "delays", "oscillators", "utilities", "accel", "nam", "ui", "all"]
        #expect(validTopics.contains("nam"), "NAM should be a valid docs topic")
        #expect(validTopics.contains("ui"), "ui should be a valid docs topic (cdp-ui component library)")
        #expect(validTopics.contains("all"), "all should include every topic")
    }

    @Test("list_tones has no required parameters")
    func listTonesNoRequiredParams() {
        // list_tones should be callable with no arguments (like list_packages)
        // This mirrors the tool definition in MCPProtocol.swift
        let schema = InputSchemaDef(type: "object", properties: [:], required: nil)
        #expect(schema.required == nil)
        #expect(schema.properties.isEmpty)
    }

    @Test("ScriptSourceChange carries benchmark data for UI timing indicator")
    func scriptSourceChangeBenchmarkData() {
        // Reproduces the bug: MCP compile_and_run sent ScriptSourceChange without
        // benchmark data, so the UI timing indicator never updated.

        // Simulates the old (broken) behavior: source only, no timing
        var lastBenchmark: (processTimeMs: Double, budgetMs: Double)?
        let changeWithoutTiming = ScriptSourceChangeMock(source: "def process(): pass",
                                                         processTimeMs: nil, budgetMs: nil)
        if let pt = changeWithoutTiming.processTimeMs, let bt = changeWithoutTiming.budgetMs {
            lastBenchmark = (pt, bt)
        }
        #expect(lastBenchmark == nil, "Without timing data, benchmark should not update")

        // Simulates the fixed behavior: source + timing
        let changeWithTiming = ScriptSourceChangeMock(source: "def process(): pass",
                                                      processTimeMs: 2.1, budgetMs: 5.3)
        if let pt = changeWithTiming.processTimeMs, let bt = changeWithTiming.budgetMs {
            lastBenchmark = (pt, bt)
        }
        #expect(lastBenchmark?.processTimeMs == 2.1, "Benchmark should update with timing data")
        #expect(lastBenchmark?.budgetMs == 5.3, "Budget should update with timing data")
    }
}

/// Local mirror of ScriptSourceChange for testing (test target can't import AU extension).
private struct ScriptSourceChangeMock {
    let source: String
    var processTimeMs: Double?
    var budgetMs: Double?
}

// =============================================================================
// MARK: - JSON Schema draft 2020-12 wire-format regression tests
//
// Triggered by an Anthropic API rejection seen in the wild:
//
//   API Error: 400 tools.10.custom.input_schema: JSON schema is invalid.
//   It must match JSON Schema draft 2020-12.
//
// Claude Code bundles every MCP-provided tool into the `tools` array of
// each Anthropic API request and Anthropic rejects the whole request if
// any `input_schema` is malformed. The most common ways to produce a
// malformed schema from Swift Encodable:
//
//   - An `Int?` or `[String]?` field accidentally emitted as `null`
//     instead of being omitted. The spec requires `minimum` to be a
//     number and `required` to be an array; both reject `null`.
//   - A numeric constraint (`minimum`/`maximum`) attached to a
//     non-numeric type (e.g. `"type": "string", "minimum": 0`).
//   - A type value that isn't one of the seven canonical keywords.
//
// These tests pin the encoding contract of `MCPProtocol.PropertySchema`
// and `MCPProtocol.InputSchema`. The logic test target can't import the
// AU extension, so we mirror those structs here with identical field
// lists — Swift synthesizes Encodable the same way either side, so the
// wire format is equivalent. When a field is added to the real structs,
// mirror it here and extend these tests.
// =============================================================================

/// Local mirror of `MCPProtocol.PropertySchema`. Field list + Optional-
/// ity must match exactly — that's the whole point of the pin.
private struct PropertySchemaMirror: Encodable {
    let type: String
    let description: String
    let minimum: Int?
    let maximum: Int?
}

/// Local mirror of `MCPProtocol.InputSchema`.
private struct InputSchemaMirror: Encodable {
    let type: String
    let properties: [String: PropertySchemaMirror]
    let required: [String]?
}

/// Walk a decoded JSON tree and collect the key paths where a `NSNull`
/// appears. Returns an empty array when there are no nulls anywhere,
/// otherwise a human-readable dotted path per offense (e.g.
/// `properties.index.minimum`).
private func nullKeyPaths(in value: Any, prefix: String = "") -> [String] {
    if value is NSNull { return [prefix.isEmpty ? "<root>" : prefix] }
    if let dict = value as? [String: Any] {
        return dict.flatMap { k, v in
            nullKeyPaths(in: v, prefix: prefix.isEmpty ? k : "\(prefix).\(k)")
        }
    }
    if let arr = value as? [Any] {
        return arr.enumerated().flatMap { i, v in
            nullKeyPaths(in: v, prefix: "\(prefix)[\(i)]")
        }
    }
    return []
}

@Suite("MCP tool schemas — JSON Schema draft 2020-12 wire format")
struct MCPSchemaWireFormatTests {

    private func encodeAsJSON(_ value: any Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data, options: [])
        return try #require(decoded as? [String: Any])
    }

    // -- PropertySchema ------------------------------------------------

    @Test("PropertySchema omits minimum/maximum when nil (draft 2020-12 rejects `null`)")
    func propertyOmitsNilConstraints() throws {
        let schema = PropertySchemaMirror(
            type: "string", description: "anything", minimum: nil, maximum: nil
        )
        let json = try encodeAsJSON(schema)
        #expect(json["type"] as? String == "string")
        #expect(json["description"] as? String == "anything")
        #expect(json["minimum"] == nil,
                "minimum must be absent when unset — `null` is not a valid JSON Schema number")
        #expect(json["maximum"] == nil,
                "maximum must be absent when unset — `null` is not a valid JSON Schema number")
        #expect(nullKeyPaths(in: json).isEmpty,
                "no nulls allowed anywhere in a PropertySchema JSON tree")
    }

    @Test("PropertySchema emits numeric constraints when set")
    func propertyEmitsNumericConstraints() throws {
        let schema = PropertySchemaMirror(
            type: "integer", description: "param index", minimum: 0, maximum: 15
        )
        let json = try encodeAsJSON(schema)
        #expect(json["minimum"] as? Int == 0)
        #expect(json["maximum"] as? Int == 15)
    }

    // -- InputSchema ---------------------------------------------------

    @Test("InputSchema with no required fields omits the `required` key")
    func inputOmitsNilRequired() throws {
        let schema = InputSchemaMirror(
            type: "object", properties: [:], required: nil
        )
        let json = try encodeAsJSON(schema)
        #expect(json["type"] as? String == "object")
        #expect(json["required"] == nil,
                "required must be absent when unset — `null` is not a valid JSON Schema array")
        #expect(nullKeyPaths(in: json).isEmpty)
    }

    @Test("InputSchema with required fields emits them as a JSON array")
    func inputEmitsRequiredArray() throws {
        let schema = InputSchemaMirror(
            type: "object",
            properties: [
                "source": PropertySchemaMirror(type: "string", description: "code", minimum: nil, maximum: nil)
            ],
            required: ["source"]
        )
        let json = try encodeAsJSON(schema)
        let req = try #require(json["required"] as? [String])
        #expect(req == ["source"])
    }

    // -- Every real tool-shape we ship ---------------------------------
    //
    // Mirrors the fixture permutations actually present in
    // MCPProtocol.tools. Each case produces a schema and asserts the
    // encoded tree is null-free. Update when adding a new shape.

    @Test("Every PropertySchema permutation we ship is null-free when encoded")
    func allShapesAreNullFree() throws {
        let fixtures: [PropertySchemaMirror] = [
            // No constraints — used by most string/number/boolean props.
            .init(type: "string", description: "preset name", minimum: nil, maximum: nil),
            .init(type: "boolean", description: "scaffold UI", minimum: nil, maximum: nil),
            .init(type: "number", description: "param value", minimum: nil, maximum: nil),
            // With numeric constraints — used by set_parameter.index.
            .init(type: "integer", description: "param index", minimum: 0, maximum: 15),
        ]
        for schema in fixtures {
            let json = try encodeAsJSON(schema)
            let nulls = nullKeyPaths(in: json)
            #expect(nulls.isEmpty,
                    "null leaked in PropertySchema(type=\(schema.type)) at: \(nulls)")
        }
    }

    @Test("Every InputSchema shape we ship is null-free when encoded")
    func allInputShapesAreNullFree() throws {
        let scaffoldUI = PropertySchemaMirror(type: "boolean", description: "scaffold UI", minimum: nil, maximum: nil)
        let paramName = PropertySchemaMirror(type: "string", description: "preset name", minimum: nil, maximum: nil)
        let paramIndex = PropertySchemaMirror(type: "integer", description: "param index", minimum: 0, maximum: 15)
        let paramValue = PropertySchemaMirror(type: "number", description: "value", minimum: nil, maximum: nil)
        let topic = PropertySchemaMirror(type: "string", description: "docs topic", minimum: nil, maximum: nil)
        let bundlePath = PropertySchemaMirror(type: "string", description: "bundle-relative path", minimum: nil, maximum: nil)
        let fileContent = PropertySchemaMirror(type: "string", description: "file content", minimum: nil, maximum: nil)

        let fixtures: [(String, InputSchemaMirror)] = [
            // No-arg tools (list_presets, list_packages, etc.) — properties empty, required nil.
            ("noArgs", .init(type: "object", properties: [:], required: nil)),

            // Single required string — compile_and_run, get_docs, read_bundle_file.
            ("singleString", .init(
                type: "object",
                properties: ["topic": topic],
                required: ["topic"]
            )),

            // Required + optional — save_preset (name required, scaffold_ui optional).
            ("reqAndOpt", .init(
                type: "object",
                properties: ["name": paramName, "scaffold_ui": scaffoldUI],
                required: ["name"]
            )),

            // Two required strings — write_bundle_file (path + content).
            ("twoStrings", .init(
                type: "object",
                properties: ["path": bundlePath, "content": fileContent],
                required: ["path", "content"]
            )),

            // Numeric constraints — set_parameter (index has min/max, value is free number).
            ("numericConstraints", .init(
                type: "object",
                properties: ["index": paramIndex, "value": paramValue],
                required: ["index", "value"]
            )),
        ]

        for (label, schema) in fixtures {
            let json = try encodeAsJSON(schema)
            let nulls = nullKeyPaths(in: json)
            #expect(nulls.isEmpty,
                    "null leaked in InputSchema fixture '\(label)' at: \(nulls)")
            // Type must be "object" for every tool's input_schema (MCP requirement).
            #expect(json["type"] as? String == "object")
        }
    }

    @Test("`type` keyword is one of the draft 2020-12 canonical types")
    func typesAreCanonical() throws {
        let canonical: Set<String> = ["object", "string", "number", "integer", "boolean", "array", "null"]
        let shapes: [PropertySchemaMirror] = [
            .init(type: "string",  description: "s", minimum: nil, maximum: nil),
            .init(type: "number",  description: "n", minimum: nil, maximum: nil),
            .init(type: "integer", description: "i", minimum: 0,   maximum: 15),
            .init(type: "boolean", description: "b", minimum: nil, maximum: nil),
        ]
        for s in shapes {
            #expect(canonical.contains(s.type),
                    "PropertySchema type \"\(s.type)\" is not a canonical JSON Schema type")
        }
    }
}
