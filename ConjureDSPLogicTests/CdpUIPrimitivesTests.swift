import Foundation
import JavaScriptCore
import Testing

/// Exercises the primitive helpers in `cdp-ui.js` (normalize,
/// denormalize, formatValue, control) by evaluating the library source
/// in a JSContext with a minimal `window.ConjureDSP` stub. Keeps the
/// fast test target doing its job — catches regressions in the log
/// curve math and unit formatting without spinning up a webview.
struct CdpUIPrimitivesTests {

    /// Locate `cdp-ui.js` regardless of where the test binary lives.
    /// Logic tests run without a host-app bundle, so walk back up from
    /// this source file's parent directory to the repo root, then into
    /// ConjureDSPExtension/Resources.
    static func loadLibrarySource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // ConjureDSPLogicTests/
            .deletingLastPathComponent()   // repo root
        let libURL = repoRoot
            .appendingPathComponent("ConjureDSPExtension")
            .appendingPathComponent("Resources")
            .appendingPathComponent("cdp-ui.js")
        return try String(contentsOf: libURL, encoding: .utf8)
    }

    /// Bootstrap a JSContext with a minimal ConjureDSP bridge stub so
    /// the library's IIFE can install `ConjureDSP.ui`. Web-Component
    /// registration is skipped by stubbing `customElements.define`
    /// (JSCore has no DOM). Returns the configured context.
    private static func makeContext(paramMetadata: [[String: Any]]) throws -> JSContext {
        let ctx = JSContext()!
        let bootstrap = """
        var window = this;
        // DOM stubs so customElements.define() doesn't throw in JSCore.
        window.customElements = { define: function(){}, get: function(){ return undefined; } };
        window.HTMLElement = function HTMLElement() {};
        window.HTMLElement.prototype.attachShadow = function () { return { append: function(){}, querySelector: function(){ return null; }, lastChild: null, innerHTML: "" }; };
        window.document = {
            createElement: function () {
                return { append: function(){}, setAttribute: function(){}, style: {}, addEventListener: function(){}, };
            },
        };
        window.addEventListener = function () {};
        var _values = [];
        var _metadata = PARAM_META_JSON;
        for (var i = 0; i < _metadata.length; i++) _values.push(_metadata[i].default || 0);
        window.ConjureDSP = {
            apiVersion: 1,
            theme: 'light',
            parameters: {
                get count() { return _metadata.length; },
                get: function(i) { return _values[i]; },
                set: function(i, v) { _values[i] = v; },
                metadata: function(i) { return _metadata[i] ? Object.assign({}, _metadata[i]) : null; },
                onChange: function(i, cb) { /* no-op for these tests */ },
                onAnyChange: function() {},
            },
            ready: function(cb) { cb(); },
            log: function() {},
        };
        """
        let metaJSON = try JSONSerialization.data(withJSONObject: paramMetadata, options: [])
        let metaString = String(data: metaJSON, encoding: .utf8)!
        ctx.evaluateScript(bootstrap.replacingOccurrences(of: "PARAM_META_JSON", with: metaString))
        ctx.evaluateScript(try loadLibrarySource())
        return ctx
    }

    // MARK: - normalize / denormalize round-trip

    @Test func linearDenormalizeIsIdentityMin() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Gain", "min": -24.0, "max": 12.0, "unit": "dB"]
        ])
        let v = ctx.evaluateScript("ConjureDSP.ui.denormalize(0, ConjureDSP.parameters.metadata(0))")!.toDouble()
        #expect(abs(v - (-24.0)) < 1e-9)
    }

    @Test func linearDenormalizeIsIdentityMax() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Gain", "min": -24.0, "max": 12.0, "unit": "dB"]
        ])
        let v = ctx.evaluateScript("ConjureDSP.ui.denormalize(1, ConjureDSP.parameters.metadata(0))")!.toDouble()
        #expect(abs(v - 12.0) < 1e-9)
    }

    @Test func logCurveDenormalizeMatchesFormula() throws {
        // freq 20..20000 log-mapped: t=0.5 => 20 * (1000)^0.5 ≈ 632.4555
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Cutoff", "min": 20.0, "max": 20000.0, "unit": "Hz", "curve": "log"]
        ])
        let v = ctx.evaluateScript("ConjureDSP.ui.denormalize(0.5, ConjureDSP.parameters.metadata(0))")!.toDouble()
        #expect(abs(v - 632.4555) < 0.01)
    }

    @Test func normalizeRoundTripsLog() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Cutoff", "min": 20.0, "max": 20000.0, "unit": "Hz", "curve": "log"]
        ])
        let t = ctx.evaluateScript("""
            var meta = ConjureDSP.parameters.metadata(0);
            ConjureDSP.ui.normalize(ConjureDSP.ui.denormalize(0.72, meta), meta);
        """)!.toDouble()
        #expect(abs(t - 0.72) < 1e-9)
    }

    // MARK: - formatValue

    @Test func formatValueHzRollsOverToKHz() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Cutoff", "min": 20.0, "max": 20000.0, "unit": "Hz"]
        ])
        let a = ctx.evaluateScript("ConjureDSP.ui.formatValue(440, ConjureDSP.parameters.metadata(0))")!.toString()!
        let b = ctx.evaluateScript("ConjureDSP.ui.formatValue(5000, ConjureDSP.parameters.metadata(0))")!.toString()!
        let c = ctx.evaluateScript("ConjureDSP.ui.formatValue(20000, ConjureDSP.parameters.metadata(0))")!.toString()!
        #expect(a == "440 Hz")
        #expect(b == "5.00 kHz")
        #expect(c == "20.0 kHz")
    }

    @Test func formatValueMsRollsOverToSeconds() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Release", "min": 0.0, "max": 5000.0, "unit": "ms"]
        ])
        let a = ctx.evaluateScript("ConjureDSP.ui.formatValue(250, ConjureDSP.parameters.metadata(0))")!.toString()!
        let b = ctx.evaluateScript("ConjureDSP.ui.formatValue(2500, ConjureDSP.parameters.metadata(0))")!.toString()!
        #expect(a == "250 ms" || a == "250.00 ms")  // generic formatter path
        #expect(b == "2.50 s")
    }

    @Test func formatValueDbTwoDecimals() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Gain", "min": -24.0, "max": 12.0, "unit": "dB"]
        ])
        let a = ctx.evaluateScript("ConjureDSP.ui.formatValue(-3.2, ConjureDSP.parameters.metadata(0))")!.toString()!
        #expect(a == "-3.20 dB")
    }

    @Test func formatValueToggle() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Bypass", "min": 0.0, "max": 1.0, "unit": "", "style": "toggle"]
        ])
        let on = ctx.evaluateScript("ConjureDSP.ui.formatValue(1, ConjureDSP.parameters.metadata(0))")!.toString()!
        let off = ctx.evaluateScript("ConjureDSP.ui.formatValue(0, ConjureDSP.parameters.metadata(0))")!.toString()!
        #expect(on == "on")
        #expect(off == "off")
    }

    @Test func formatValueChoiceIndexesOptions() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Mode", "min": 0.0, "max": 2.0, "style": "choice", "options": ["Low", "Mid", "High"]]
        ])
        let a = ctx.evaluateScript("ConjureDSP.ui.formatValue(0, ConjureDSP.parameters.metadata(0))")!.toString()!
        let b = ctx.evaluateScript("ConjureDSP.ui.formatValue(2, ConjureDSP.parameters.metadata(0))")!.toString()!
        #expect(a == "Low")
        #expect(b == "High")
    }

    // MARK: - version contract

    @Test func versionIsPositiveInt() throws {
        let ctx = try Self.makeContext(paramMetadata: [])
        let v = ctx.evaluateScript("ConjureDSP.ui.version")!.toInt32()
        #expect(v >= 1)
    }

    @Test func requireVersionPassesAtOrBelow() throws {
        let ctx = try Self.makeContext(paramMetadata: [])
        ctx.evaluateScript("ConjureDSP.ui.requireVersion(1)")
        #expect(ctx.exception == nil)
    }

    @Test func requireVersionThrowsAboveCurrent() throws {
        let ctx = try Self.makeContext(paramMetadata: [])
        ctx.evaluateScript("try { ConjureDSP.ui.requireVersion(999); } catch (e) { globalThis._err = e.message; }")
        let msg = ctx.evaluateScript("globalThis._err")!.toString()!
        #expect(msg.contains("too old"))
    }

    // MARK: - normalizeParamName

    @Test func normalizeParamNameStripsCaseAndPunct() throws {
        let ctx = try Self.makeContext(paramMetadata: [])
        let cases: [(String, String)] = [
            ("low_gain", "lowgain"),
            ("LOW_GAIN", "lowgain"),
            ("Low Gain", "lowgain"),
            ("low gain", "lowgain"),
            ("  Low-Gain!  ", "lowgain"),
            ("", ""),
        ]
        for (input, expected) in cases {
            let escaped = input.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "\"", with: "\\\"")
            let got = ctx.evaluateScript("ConjureDSP.ui.normalizeParamName(\"\(escaped)\")")!.toString()!
            #expect(got == expected, "normalize(\(input)) — got \(got), want \(expected)")
        }
    }

    @Test func normalizeParamNameHandlesNullish() throws {
        let ctx = try Self.makeContext(paramMetadata: [])
        let a = ctx.evaluateScript("ConjureDSP.ui.normalizeParamName(null)")!.toString()!
        let b = ctx.evaluateScript("ConjureDSP.ui.normalizeParamName(undefined)")!.toString()!
        #expect(a == "")
        #expect(b == "")
    }

    // MARK: - findParam (the lookup used by every <cdp-* param="…">)

    /// Python-style name: exact match against the dict key.
    @Test func findParamExactMatchPython() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "cutoff", "min": 20.0, "max": 20000.0, "unit": "Hz"]
        ])
        let i = ctx.evaluateScript("ConjureDSP.ui.findParam('cutoff')")!.toInt32()
        #expect(i == 0)
    }

    /// Rust-style Title Case name (`stringify!($NAME)` → Title Case with
    /// spaces). The SAME UI tag in a bundle serving both variants must
    /// resolve the parameter either way.
    @Test func findParamMatchesRustTitleCaseFromSnakeCaseAttr() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Low Gain", "min": -12.0, "max": 12.0, "unit": "dB"]
        ])
        // UI author writes `<cdp-slider param="low_gain">`; metadata
        // comes from Rust as "Low Gain". Must still resolve to index 0.
        let i = ctx.evaluateScript("ConjureDSP.ui.findParam('low_gain')")!.toInt32()
        #expect(i == 0, "Rust-title-cased metadata must be findable via snake_case attribute")
    }

    @Test func findParamMatchesUppercaseIdent() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "LOW_GAIN", "min": -12.0, "max": 12.0, "unit": "dB"]
        ])
        let i = ctx.evaluateScript("ConjureDSP.ui.findParam('low_gain')")!.toInt32()
        #expect(i == 0)
    }

    @Test func findParamAcceptsNumericString() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "A"], ["name": "B"], ["name": "C"]
        ])
        let i0 = ctx.evaluateScript("ConjureDSP.ui.findParam('0')")!.toInt32()
        let i2 = ctx.evaluateScript("ConjureDSP.ui.findParam('2')")!.toInt32()
        #expect(i0 == 0)
        #expect(i2 == 2)
    }

    @Test func findParamReturnsMinusOneWhenMissing() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "cutoff"]
        ])
        let miss = ctx.evaluateScript("ConjureDSP.ui.findParam('resonance')")!.toInt32()
        let empty = ctx.evaluateScript("ConjureDSP.ui.findParam('')")!.toInt32()
        let oob = ctx.evaluateScript("ConjureDSP.ui.findParam('99')")!.toInt32()
        #expect(miss == -1)
        #expect(empty == -1)
        #expect(oob == -1)
    }

    @Test func findParamExactBeatsNormalized() throws {
        // If a bundle really does ship two params that normalize to
        // the same thing (pathological, but possible), exact match
        // should win over normalized.
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Low Gain"],
            ["name": "low_gain"],
        ])
        let i = ctx.evaluateScript("ConjureDSP.ui.findParam('low_gain')")!.toInt32()
        #expect(i == 1, "exact 'low_gain' match must win over normalized 'Low Gain'")
    }

    // MARK: - control() primitive

    @Test func controlReadsAndWritesValue() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "gain", "min": -24.0, "max": 12.0, "unit": "dB", "default": 0.0]
        ])
        let initial = ctx.evaluateScript("ConjureDSP.ui.control(0).value")!.toDouble()
        #expect(initial == 0.0)

        // setValue round-trips through the stubbed bridge.
        ctx.evaluateScript("ConjureDSP.ui.control(0).setValue(-6.5)")
        let after = ctx.evaluateScript("ConjureDSP.parameters.get(0)")!.toDouble()
        #expect(after == -6.5)
    }

    @Test func controlExposesNormalizeDenormalize() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "cutoff", "min": 20.0, "max": 20000.0, "unit": "Hz", "curve": "log"]
        ])
        let mid = ctx.evaluateScript("ConjureDSP.ui.control(0).denormalize(0.5)")!.toDouble()
        #expect(abs(mid - 632.4555) < 0.01)
        let roundTrip = ctx.evaluateScript("""
            var c = ConjureDSP.ui.control(0);
            c.normalize(c.denormalize(0.8));
        """)!.toDouble()
        #expect(abs(roundTrip - 0.8) < 1e-9)
    }

    @Test func controlFormatUsesMetadata() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Cutoff", "min": 20.0, "max": 20000.0, "unit": "Hz"]
        ])
        let label = ctx.evaluateScript("ConjureDSP.ui.control(0).format(5000)")!.toString()!
        #expect(label == "5.00 kHz")
    }

    // MARK: - formatValue edge cases

    @Test func formatValuePercentRoundsInteger() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Mix", "min": 0.0, "max": 100.0, "unit": "%"]
        ])
        let a = ctx.evaluateScript("ConjureDSP.ui.formatValue(42.7, ConjureDSP.parameters.metadata(0))")!.toString()!
        #expect(a == "43%")
    }

    @Test func formatValueIntegerStyleHasNoDecimal() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Voices", "min": 1.0, "max": 16.0, "style": "integer", "unit": "v"]
        ])
        let a = ctx.evaluateScript("ConjureDSP.ui.formatValue(5.7, ConjureDSP.parameters.metadata(0))")!.toString()!
        #expect(a == "6 v")
    }

    @Test func formatValueHandlesNaN() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Gain", "min": -24.0, "max": 12.0, "unit": "dB"]
        ])
        let a = ctx.evaluateScript("ConjureDSP.ui.formatValue(NaN, ConjureDSP.parameters.metadata(0))")!.toString()!
        #expect(a == "—")
    }

    // MARK: - denormalize edge cases

    @Test func denormalizeLinearWithZeroRange() throws {
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Constant", "min": 5.0, "max": 5.0]
        ])
        let a = ctx.evaluateScript("ConjureDSP.ui.denormalize(0.5, ConjureDSP.parameters.metadata(0))")!.toDouble()
        #expect(a == 5.0)
    }

    @Test func denormalizeLogRejectsNonPositiveRange() throws {
        // A log-curved range that crosses zero falls back to linear —
        // Math.log(0) is -Infinity, so we can't do the geometric map.
        let ctx = try Self.makeContext(paramMetadata: [
            ["name": "Bad", "min": 0.0, "max": 100.0, "curve": "log"]
        ])
        let a = ctx.evaluateScript("ConjureDSP.ui.denormalize(0.5, ConjureDSP.parameters.metadata(0))")!.toDouble()
        #expect(a == 50.0, "log curve with non-positive min should fall back to linear")
    }

    // MARK: - Component registration

    @Test func componentsRegisterOnLoad() throws {
        // Install a recording `customElements.define` stub, then clear
        // `ConjureDSP.ui` so the library's double-load guard lets the
        // IIFE re-run against our spy.
        let ctx = try Self.makeContext(paramMetadata: [])
        ctx.evaluateScript("""
            var definedTags = [];
            window.customElements = {
                define: function(name) { definedTags.push(name); },
                get: function() { return undefined; }
            };
            delete window.ConjureDSP.ui;
        """)
        ctx.evaluateScript(try Self.loadLibrarySource())
        let tags = ctx.evaluateScript("definedTags.join(',')")!.toString()!
        for expected in ["cdp-slider", "cdp-toggle", "cdp-choice", "cdp-xy", "cdp-panel"] {
            #expect(tags.contains(expected), "expected \(expected) to be registered; got: \(tags)")
        }
    }
}
