import Testing

// =============================================================================
// Self-contained ScriptLanguage tests. Enum copied from ScriptLanguage.swift
// to avoid importing the extension target.
// =============================================================================

// ScriptLanguage is already available in the test target via ScriptLanguage.swift,
// so we use it directly (no need to copy).

// =============================================================================
// MARK: - Tests
// =============================================================================

@Suite("ScriptLanguage Detection")
struct ScriptLanguageDetectionTests {

    @Test func detectFnProcessReturnsRust() {
        let source = "fn process(ctx: &mut Context) { }"
        #expect(ScriptLanguage.detect(from: source) == .rust)
    }

    @Test func detectNoMangleReturnsRust() {
        let source = "#[no_mangle]\npub extern \"C\" fn get_param() -> f32 { 0.0 }"
        #expect(ScriptLanguage.detect(from: source) == .rust)
    }

    @Test func detectUseConjuredspReturnsRust() {
        let source = "use conjuredsp::*;\nfn main() {}"
        #expect(ScriptLanguage.detect(from: source) == .rust)
    }

    @Test func detectSetupMacroReturnsRust() {
        let source = "setup!()\nfn process() {}"
        #expect(ScriptLanguage.detect(from: source) == .rust)
    }

    @Test func detectDefProcessReturnsPython() {
        let source = "def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):\n    pass"
        #expect(ScriptLanguage.detect(from: source) == .python)
    }

    @Test func detectEmptyStringReturnsPython() {
        #expect(ScriptLanguage.detect(from: "") == .python)
    }

    @Test func detectAmbiguousReturnsPython() {
        let source = "# Some comment\nimport numpy\nx = 42"
        #expect(ScriptLanguage.detect(from: source) == .python)
    }
}
