import AppKit
import Foundation
import Testing
import WebKit

/// Attempted DOM-level integration tests for the `cdp-ui` component
/// library.
///
/// **Status: infrastructure only.** The JSCore tests in
/// `ConjureDSPLogicTests/CdpUIPrimitivesTests` (29 tests) cover
/// primitives, `findParam` lookup (including the Rust Title-Case ↔
/// snake_case attribute fix), `control()`, formatting, and component
/// *registration* (each `<cdp-*>` tag calls `customElements.define`).
///
/// What these tests *would* add is DOM-level verification of the
/// rendered shadow roots — slider label text, toggle aria-checked,
/// choice segmented vs. dropdown switching, panel auto child count,
/// theme attribute adoption, XY puck position.
///
/// We hit a WebKit test-host quirk: under the `ConjureDSPTests` host
/// sandbox, WKWebView does not upgrade custom elements — neither
/// from parsed HTML (elements stay `HTMLUnknownElement` even after
/// `customElements.define` succeeds), nor from `document.createElement`.
/// The live plugin UI works correctly in the real app; only the test
/// environment is broken. The smoke test below proves DOM access and
/// evaluation work; the component upgrade path is the specific
/// failure mode.
///
/// Likely paths to unblock later:
///   1. File a WebKit radar / investigate entitlements so upgrades
///      work under the test-host sandbox.
///   2. Run these against the real extension's webview (harder —
///      needs a test hook into `CustomUIWebView`).
///   3. Use a headless Chromium via CDP (much heavier infrastructure).
///
/// Until then the manual test path remains: open the plugin, load a
/// preset that uses `<cdp-panel auto>` or specific components, verify
/// rendering.
@MainActor
@Suite("CdpUIComponentTests", .serialized)
struct CdpUIComponentTests {

    // MARK: - Library source loading

    static func loadLibrarySource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let libURL = repoRoot
            .appendingPathComponent("ConjureDSPExtension")
            .appendingPathComponent("Resources")
            .appendingPathComponent("cdp-ui.js")
        return try String(contentsOf: libURL, encoding: .utf8)
    }

    // MARK: - Harness (kept for when the WebKit issue gets unblocked)

    @MainActor
    final class Harness {
        let webView: WKWebView
        private let delegate: Delegate
        private let window: NSWindow

        init(html: String) throws {
            let config = WKWebViewConfiguration()

            // Minimal subset of customui-bridge.js — only what the
            // library's components touch. Components register handlers
            // via `parameters.onChange`; external updates fire through
            // `_paramUpdate`; ready is queued until `_init` lands.
            let bootstrap = """
            window.ConjureDSP = {
                apiVersion: 1,
                theme: 'light',
                _ready: false,
                _readyHandlers: [],
                parameters: {
                    _metadata: [], _values: [], _handlers: {}, _anyHandlers: [],
                    get count() { return this._metadata.length; },
                    get: function(i) { return this._values[i]; },
                    set: function(i, v) {
                        var n = Number(v);
                        if (!isFinite(n)) return;
                        this._values[i] = n;
                    },
                    metadata: function(i) {
                        var m = this._metadata[i];
                        return m ? Object.assign({}, m) : null;
                    },
                    onChange: function(i, cb) {
                        if (typeof cb !== 'function') return;
                        var key = String(i);
                        (this._handlers[key] = this._handlers[key] || []).push(cb);
                    },
                    onAnyChange: function(cb) {
                        if (typeof cb === 'function') this._anyHandlers.push(cb);
                    },
                },
                ready: function(cb) {
                    if (this._ready) cb();
                    else this._readyHandlers.push(cb);
                },
                log: function() {},
                _init: function(state) {
                    this.parameters._metadata = (state && state.metadata) ? state.metadata.slice() : [];
                    this.parameters._values = (state && state.values) ? state.values.slice() : [];
                    this.theme = (state && state.theme) || 'light';
                    this._ready = true;
                    var hs = this._readyHandlers.slice();
                    this._readyHandlers.length = 0;
                    for (var i = 0; i < hs.length; i++) {
                        try { hs[i](); } catch (e) {}
                    }
                    try { window.dispatchEvent(new CustomEvent('ConjureDSPReady')); } catch (_) {}
                },
                _paramUpdate: function(i, v) {
                    this.parameters._values[i] = v;
                    var hs = this.parameters._handlers[String(i)] || [];
                    for (var k = 0; k < hs.length; k++) {
                        try { hs[k](v); } catch (e) {}
                    }
                    for (var j = 0; j < this.parameters._anyHandlers.length; j++) {
                        try { this.parameters._anyHandlers[j](i, v); } catch (e) {}
                    }
                },
                _setTheme: function(t) {
                    this.theme = t;
                    try { window.dispatchEvent(new CustomEvent('themechange', { detail: { theme: t } })); } catch (_) {}
                },
            };
            """
            config.userContentController.addUserScript(
                WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            config.userContentController.addUserScript(
                WKUserScript(source: try Self.loadLibrarySource(), injectionTime: .atDocumentStart, forMainFrameOnly: true))

            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
            delegate = Delegate()
            webView.navigationDelegate = delegate

            // Attach to an off-screen window so WebContent initializes
            // reliably under the test-host sandbox.
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = webView
            window.orderOut(nil)

            let fullHtml = "<!DOCTYPE html><html><head><meta charset='utf-8'></head><body>\(html)</body></html>"
            webView.loadHTMLString(fullHtml, baseURL: URL(string: "about:blank"))
        }

        private static func loadLibrarySource() throws -> String {
            try CdpUIComponentTests.loadLibrarySource()
        }

        func waitForNavigation() async { await delegate.wait() }

        @discardableResult
        func eval(_ js: String) async throws -> Any? {
            try await webView.evaluateJavaScript(js)
        }
    }

    @MainActor
    private final class Delegate: NSObject, WKNavigationDelegate {
        private var finished = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if finished { return }
            await withCheckedContinuation { cont in continuations.append(cont) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
            let pending = continuations
            continuations = []
            for c in pending { c.resume() }
        }
    }

    // MARK: - Smoke test

    /// Verifies the harness infrastructure (WKWebView in off-screen
    /// window, user-script injection, `evaluateJavaScript` round-trip,
    /// bootstrap + library load order) all work against a normal DOM
    /// element. When the WebKit custom-element upgrade issue is fixed
    /// this file can grow to cover slider/toggle/choice/panel/xy/theme
    /// — the harness is already shaped for it.
    @Test func harnessLoadsDomAndEvaluatesScript() async throws {
        let h = try Harness(html: "<div id='x'>hello</div>")
        await h.waitForNavigation()
        let text = try await h.eval("document.getElementById('x').textContent") as? String
        #expect(text == "hello")

        // Library + bootstrap are installed: both ConjureDSP.ui and the
        // custom element registrations should be present, even if
        // instances of them don't get upgraded here.
        let uiDefined = try await h.eval("typeof ConjureDSP !== 'undefined' && typeof ConjureDSP.ui !== 'undefined'") as? Bool
        let sliderRegistered = try await h.eval("!!customElements.get('cdp-slider')") as? Bool
        let panelRegistered = try await h.eval("!!customElements.get('cdp-panel')") as? Bool
        #expect(uiDefined == true, "library failed to install ConjureDSP.ui")
        #expect(sliderRegistered == true, "cdp-slider not registered with customElements")
        #expect(panelRegistered == true, "cdp-panel not registered with customElements")
    }

    /// Verifies the library's public JS API is reachable from the
    /// webview — same functions the JSCore tests exercise, but through
    /// the real WebKit engine. Guards against the library being subtly
    /// broken when run in a browser vs. JavaScriptCore.
    @Test func libraryApiReachableInWebKit() async throws {
        let h = try Harness(html: "")
        await h.waitForNavigation()

        let apiVersion = try await h.eval("ConjureDSP.apiVersion") as? Int
        let libVersion = try await h.eval("ConjureDSP.ui.version") as? Int
        let normalized = try await h.eval("ConjureDSP.ui.normalizeParamName('Low Gain')") as? String
        #expect(apiVersion == 1)
        #expect(libVersion == 1)
        #expect(normalized == "lowgain")

        // Prime with metadata, then resolve a snake_case attribute
        // against a Title-Cased name — the exact scenario that was
        // breaking in Rust-variant preset UIs.
        try await h.eval("""
            ConjureDSP._init({
                metadata: [{name: 'Low Gain', min: -12, max: 12, unit: 'dB', default: 0}],
                values: [0],
                theme: 'dark'
            })
        """)
        let resolved = try await h.eval("ConjureDSP.ui.findParam('low_gain')") as? Int
        #expect(resolved == 0, "Rust Title-Cased metadata must be findable from a snake_case attribute in WebKit, not just JSCore")
    }
}
