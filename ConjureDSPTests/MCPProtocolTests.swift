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
