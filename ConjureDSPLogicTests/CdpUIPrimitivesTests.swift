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
    private static func loadLibrarySource() throws -> String {
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
}
