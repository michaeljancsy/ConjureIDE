import Foundation
import Testing

/// Test-target mirror of `ConjureDSPExtensionAudioUnit.coerceBool`.
/// The canonical impl lives in `ConjureDSPExtensionAudioUnit+MCP.swift`
/// — same duplication pattern as `roundForDisplay` in
/// `MCPProtocolTests.swift` (extension symbols can't be linked into
/// the test target without producing duplicate-symbol clashes when the
/// AU loads in-process).
///
/// **Whenever the runtime impl changes, mirror the change here.**
private func coerceBool(_ value: Any?) -> Bool? {
    switch value {
    case let b as Bool:
        return b
    case let s as String:
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    case let i as Int:
        if i == 0 { return false }
        if i == 1 { return true }
        return nil
    case let d as Double:
        if d == 0.0 { return false }
        if d == 1.0 { return true }
        return nil
    default:
        return nil
    }
}

/// Pins the lenient bool-coercion contract on MCP tool inputs. Driven
/// by Failures #1 / #3 / #4 in the 2026-05-08 /try-it sweep — Sonnet
/// routinely sent `"scaffold_ui": "true"` as a JSON string and the
/// strict `as? Bool` cast silently dropped it to nil → defaulted to
/// false → scaffold became a no-op while the response payload still
/// looked like success.
@Suite("MCP coerceBool input parsing")
struct MCPCoerceBoolTests {

    // MARK: - Native bool (the schema-correct happy path)

    @Test("Native true decodes as true")
    func nativeBoolTrue() {
        #expect(coerceBool(true) == true)
    }

    @Test("Native false decodes as false")
    func nativeBoolFalse() {
        #expect(coerceBool(false) == false)
    }

    // MARK: - JSON string (what Sonnet kept sending)

    @Test("\"true\" string decodes as true")
    func stringTrue() {
        #expect(coerceBool("true") == true,
                "Sonnet routinely sends scaffold_ui as a JSON string. Strict-rejecting it forced the agent to hand-author the manifest+ui block from scratch.")
    }

    @Test("\"false\" string decodes as false")
    func stringFalse() {
        #expect(coerceBool("false") == false)
    }

    @Test("Mixed-case strings decode case-insensitively")
    func stringCaseInsensitive() {
        #expect(coerceBool("True") == true)
        #expect(coerceBool("TRUE") == true)
        #expect(coerceBool("False") == false)
        #expect(coerceBool("FALSE") == false)
    }

    @Test("Whitespace around string values is tolerated")
    func stringWhitespace() {
        #expect(coerceBool(" true ") == true)
        #expect(coerceBool("\nfalse\n") == false)
    }

    @Test("\"yes\"/\"no\" decode as the matching bool")
    func stringYesNo() {
        #expect(coerceBool("yes") == true)
        #expect(coerceBool("no") == false)
    }

    @Test("\"1\"/\"0\" strings decode as true/false")
    func stringDigit() {
        #expect(coerceBool("1") == true)
        #expect(coerceBool("0") == false)
    }

    // MARK: - Numeric (defensive — JSON numbers can decode either way)

    @Test("Integer 1 decodes as true, 0 as false")
    func integerBinary() {
        #expect(coerceBool(1) == true)
        #expect(coerceBool(0) == false)
    }

    @Test("Double 1.0/0.0 decode as true/false")
    func doubleBinary() {
        #expect(coerceBool(1.0) == true)
        #expect(coerceBool(0.0) == false)
    }

    // MARK: - Reject the unrecognizable

    @Test("Garbage strings return nil so callers fall back to the documented default")
    func garbageStringIsNil() {
        #expect(coerceBool("maybe") == nil)
        #expect(coerceBool("") == nil)
        #expect(coerceBool("on") == nil,
                "We don't pretend to support every truthy synonym — only the ones JSON producers actually emit.")
    }

    @Test("Out-of-range numbers return nil")
    func outOfRangeNumberIsNil() {
        #expect(coerceBool(2) == nil)
        #expect(coerceBool(-1) == nil)
        #expect(coerceBool(3.14) == nil)
    }

    @Test("nil and unsupported types return nil")
    func nilAndOddTypesReturnNil() {
        #expect(coerceBool(nil) == nil)
        #expect(coerceBool([1, 2, 3]) == nil)
        #expect(coerceBool(["k": "v"]) == nil)
    }
}
