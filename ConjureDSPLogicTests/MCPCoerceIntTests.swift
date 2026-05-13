import Foundation
import Testing

/// Test-target mirror of `ConjureDSPExtensionAudioUnit.coerceInt`.
/// Same duplication pattern as `MCPCoerceBoolTests` — extension symbols
/// can't be linked into the test target without duplicate-symbol
/// clashes when the AU loads in-process.
///
/// **Whenever the runtime impl changes, mirror the change here.**
private func coerceInt(_ value: Any?) -> Int? {
    if value is Bool { return nil }
    switch value {
    case let i as Int:
        return i
    case let d as Double:
        if d.rounded() == d, d >= Double(Int.min), d <= Double(Int.max) {
            return Int(d)
        }
        return nil
    case let s as String:
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        return nil
    }
}

private func coerceInt(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
    guard let v = coerceInt(value) else { return nil }
    return range.contains(v) ? v : nil
}

/// Pins the lenient integer-coercion contract for MCP tool inputs.
/// `save_preset` introduced the first integer args on the MCP surface
/// (`ui_width`, `ui_height`); the same coercion rules apply going
/// forward to any new integer params. Driven by the same root cause as
/// `coerceBool`: agents routinely send JSON numbers as strings ("360")
/// or as Doubles, and a strict `as? Int` cast silently drops both to
/// nil → defaulted to the scaffold default → the agent's requested
/// dimensions are quietly ignored while the response looks like
/// success.
@Suite("MCP coerceInt input parsing")
struct MCPCoerceIntTests {

    // MARK: - Native int (the schema-correct happy path)

    @Test("Native positive int decodes as itself")
    func nativePositiveInt() {
        #expect(coerceInt(360) == 360)
    }

    @Test("Native zero decodes as zero")
    func nativeZero() {
        #expect(coerceInt(0) == 0)
    }

    @Test("Native negative int decodes as itself")
    func nativeNegativeInt() {
        // Range validation belongs at the call site (e.g. the schema
        // declares minimum: 120 for ui_width). The coercer itself
        // doesn't clamp — same shape as coerceBool not rejecting -1.
        #expect(coerceInt(-50) == -50)
    }

    // MARK: - JSON string (what agents send through Sonnet)

    @Test("\"360\" string decodes as 360")
    func stringInt() {
        #expect(coerceInt("360") == 360,
                "agents commonly send integer args as JSON strings — strict-rejecting them silently drops the value to the default.")
    }

    @Test("Whitespace around string values is tolerated")
    func stringWhitespace() {
        #expect(coerceInt(" 360 ") == 360)
        #expect(coerceInt("\n280\n") == 280)
    }

    @Test("\"-50\" string decodes as -50")
    func stringNegativeInt() {
        #expect(coerceInt("-50") == -50)
    }

    @Test("\"+360\" string decodes as 360")
    func stringExplicitPositiveInt() {
        // Swift's Int(_:) accepts a leading +.
        #expect(coerceInt("+360") == 360)
    }

    // MARK: - Double (JSON numbers may decode either way)

    @Test("Integer-valued double decodes as int")
    func integerDouble() {
        #expect(coerceInt(360.0) == 360)
        #expect(coerceInt(0.0) == 0)
    }

    @Test("Fractional doubles return nil")
    func fractionalDoubleIsNil() {
        // The schema declares integer for ui_width / ui_height; a
        // fractional value is more likely a bug than a rounding
        // request. Reject explicitly rather than silently truncate.
        #expect(coerceInt(280.5) == nil)
        #expect(coerceInt(3.14) == nil)
    }

    @Test("Extreme doubles outside Int range return nil")
    func extremeDoubleIsNil() {
        // Guards against `Int(d)` trap on out-of-range conversion.
        #expect(coerceInt(1.0e30) == nil)
        #expect(coerceInt(-1.0e30) == nil)
    }

    // MARK: - Reject the unrecognizable

    @Test("Non-numeric strings return nil")
    func garbageStringIsNil() {
        #expect(coerceInt("wide") == nil)
        #expect(coerceInt("") == nil)
        #expect(coerceInt("360px") == nil,
                "We don't strip unit suffixes — the schema is unambiguous about expecting a bare integer.")
    }

    @Test("nil and unsupported types return nil")
    func nilAndOddTypesReturnNil() {
        #expect(coerceInt(nil) == nil)
        #expect(coerceInt(true) == nil,
                "Bools are not numeric in the MCP integer sense — let coerceBool handle them.")
        #expect(coerceInt([1, 2, 3]) == nil)
        #expect(coerceInt(["k": "v"]) == nil)
    }

    /// Production path: agents send JSON via the MCP HTTP server, which
    /// goes through `JSONSerialization`. JSON booleans land as
    /// `NSNumber(value: Bool)` — and `NSNumber(value: true) as? Int`
    /// returns 1 in Foundation. Without the explicit Bool reject before
    /// the Int case, `ui_width: true` would silently become `1`.
    @Test("NSNumber-bridged JSON true rejects as nil, not 1")
    func jsonBoolFromNSNumberIsNil() throws {
        let json = "{\"x\": true}".data(using: .utf8)!
        let dict = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let x = dict["x"]
        #expect(coerceInt(x) == nil,
                "NSNumber(true) matches `as? Int` (returning 1). The Bool guard must catch it before the Int case.")
    }

    /// Same path, JSON `1` (integer) lands as `NSNumber` and SHOULD
    /// coerce to 1. Catches a regression where the Bool guard was
    /// over-eager and rejected NSNumber-wrapped integers.
    @Test("NSNumber-bridged JSON integer coerces as expected")
    func jsonIntegerFromNSNumberCoerces() throws {
        let json = "{\"x\": 360}".data(using: .utf8)!
        let dict = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let x = dict["x"]
        #expect(coerceInt(x) == 360)
    }

    // MARK: - Range-checked variant (coerceInt(_:in:))

    /// In-range integers pass through unchanged.
    @Test("In-range value returns itself")
    func rangeInRange() {
        #expect(coerceInt(360, in: 120...1600) == 360)
        #expect(coerceInt(120, in: 120...1600) == 120, "lower bound inclusive")
        #expect(coerceInt(1600, in: 120...1600) == 1600, "upper bound inclusive")
    }

    /// Out-of-range integers return nil so the caller falls back to its
    /// documented default — same shape as `coerceInt` returning nil for
    /// garbage strings. This is the fix for the schema-declared
    /// `minimum`/`maximum` not being enforced server-side (Seer
    /// Reference ID: 14059401).
    @Test("Out-of-range value returns nil")
    func rangeOutOfRange() {
        #expect(coerceInt(50, in: 120...1600) == nil,
                "below minimum → nil so caller drops to default rather than writing a degenerate width to disk")
        #expect(coerceInt(2000, in: 120...1600) == nil, "above maximum → nil")
        #expect(coerceInt(-50, in: 120...1600) == nil, "negative → nil")
        #expect(coerceInt(0, in: 120...1600) == nil)
    }

    /// String inputs go through the base coerceInt first, then the
    /// range check, so "360" → 360 → in range.
    @Test("String inputs honor the range check")
    func rangeStringInputs() {
        #expect(coerceInt("360", in: 120...1600) == 360)
        #expect(coerceInt("50", in: 120...1600) == nil, "string below minimum → nil")
        #expect(coerceInt("not-a-number", in: 120...1600) == nil, "non-numeric short-circuits before range check")
    }

    /// Boolean rejection in the base function carries through.
    @Test("Bool rejected by range variant just like base variant")
    func rangeRejectsBool() {
        #expect(coerceInt(true, in: 0...10) == nil,
                "true would have to land as 1, but the Bool guard in base coerceInt fires first → nil")
    }
}
