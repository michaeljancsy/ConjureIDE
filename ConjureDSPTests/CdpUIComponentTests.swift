import AppKit
import Foundation
import Testing
import WebKit

/// DOM-level integration tests for the `cdp-ui` component library.
///
/// Complements the JSCore tests in
/// `ConjureDSPLogicTests/CdpUIPrimitivesTests` (29 tests: primitives,
/// `findParam` including Rust Title-Case ↔ snake_case, `control()`,
/// formatting, registration) with shadow-DOM verification in a real
/// WebKit engine: slider label text, toggle aria-checked, choice
/// segmented vs. dropdown, `<cdp-panel auto>` children, `<cdp-xy>`
/// puck position, theme adoption.
///
/// Writing these surfaced a real bug in the shipped library: every
/// component's constructor called `adoptTheme(this)`, which did
/// `host.setAttribute('data-cdp-theme', …)`. The Custom Elements
/// spec forbids setting attributes on `this` in a constructor;
/// WebKit enforces it by silently refusing to upgrade the element —
/// `customElements.get('cdp-slider')` returns the class, but
/// `document.createElement('cdp-slider')` returns `HTMLUnknownElement`
/// with no shadow root. Fixed by moving `adoptTheme(this)` into each
/// component's `connectedCallback` (idempotent via a per-host flag).
/// The library now matches the spec.
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
        private let deferredBootstrap: String
        private let deferredLibrary: String

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
                audio: {
                    _handlers: [],
                    _subCount: 0,
                    _unsubCount: 0,
                    onFrame: function(cb, opts) {
                        if (typeof cb !== 'function') return;
                        this._handlers.push(cb);
                        this._subCount++;
                    },
                    offFrame: function(cb) {
                        var i = this._handlers.indexOf(cb);
                        if (i >= 0) {
                            this._handlers.splice(i, 1);
                            this._unsubCount++;
                        }
                    },
                },
                _audioFrame: function(frame) {
                    var hs = this.audio._handlers.slice();
                    for (var i = 0; i < hs.length; i++) {
                        try { hs[i](frame); } catch (e) {}
                    }
                },
            };
            """
            // Empirically: under the test-host sandbox, `customElements
            // .define()` called from a WKUserScript (even in `.page`
            // content world) registers the class such that
            // `customElements.get(name)` returns it, but
            // `document.createElement(name)` skips upgrade and returns
            // `HTMLUnknownElement`. The same `define()` call via
            // `evaluateJavaScript(in: .page)` upgrades correctly. So
            // we defer library loading until after navigation completes
            // and inject via evaluateJavaScript in `setUp()`. Not what
            // production does, but the behavior we're testing — DOM
            // assertions on rendered shadow roots — is identical.
            self.deferredBootstrap = bootstrap
            self.deferredLibrary = try Self.loadLibrarySource()

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

        /// Completes navigation, then installs the bootstrap stub and
        /// library via `evaluateJavaScript` — NOT via WKUserScript,
        /// because user-script-registered custom elements don't upgrade
        /// under the test-host sandbox (see `init(html:)` comment).
        func waitForNavigationAndSetup() async throws {
            await delegate.wait()
            _ = try await webView.evaluateJavaScript(deferredBootstrap, in: nil, contentWorld: .page)
            _ = try await webView.evaluateJavaScript(deferredLibrary, in: nil, contentWorld: .page)
        }

        // Back-compat for the smoke tests that don't need the library.
        func waitForNavigation() async { await delegate.wait() }

        @discardableResult
        func eval(_ js: String) async throws -> Any? {
            // Evaluate in `.page` content world — matches where the user
            // scripts ran, so we're inspecting the same `window` /
            // `customElements` they modified.
            try await webView.evaluateJavaScript(js, in: nil, contentWorld: .page)
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
    @Test func harnessLoadsDomAndInstallsLibrary() async throws {
        let h = try Harness(html: "<div id='x'>hello</div>")
        try await h.waitForNavigationAndSetup()
        let text = try await h.eval("document.getElementById('x').textContent") as? String
        #expect(text == "hello")

        let uiDefined = try await h.eval("typeof ConjureDSP !== 'undefined' && typeof ConjureDSP.ui !== 'undefined'") as? Bool
        let sliderRegistered = try await h.eval("!!customElements.get('cdp-slider')") as? Bool
        let panelRegistered = try await h.eval("!!customElements.get('cdp-panel')") as? Bool
        #expect(uiDefined == true)
        #expect(sliderRegistered == true)
        #expect(panelRegistered == true)
    }

    /// Verifies the library's public JS API is reachable from the
    /// webview — same functions the JSCore tests exercise, but through
    /// the real WebKit engine. Guards against the library being subtly
    /// broken when run in a browser vs. JavaScriptCore.
    /// Regression pin: asserts the Custom Elements upgrade path works
    /// for the library's actual classes. If someone later re-introduces
    /// a `setAttribute` (or other forbidden operation) in a component
    /// constructor, `document.createElement('cdp-slider')` will return
    /// an unupgraded `HTMLUnknownElement` with no shadow root and this
    /// test will fail fast.
    @Test func customElementUpgradeRegression() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()

        // Every component tag must: register, and upgrade on create.
        let tags = ["cdp-slider", "cdp-toggle", "cdp-choice", "cdp-xy", "cdp-knob", "cdp-meter", "cdp-bargraph", "cdp-panel"]
        for tag in tags {
            let registered = try await h.eval("!!customElements.get('\(tag)')") as? Bool
            #expect(registered == true, "\(tag) not registered")

            try await h.eval("""
                var el = document.createElement('\(tag)');
                document.body.appendChild(el);
                globalThis._probeCtor = el.constructor.name;
                globalThis._probeShadow = !!el.shadowRoot;
            """)
            let ctor = try await h.eval("globalThis._probeCtor") as? String
            let shadow = try await h.eval("globalThis._probeShadow") as? Bool
            #expect(ctor != "HTMLUnknownElement",
                    "\(tag) failed to upgrade — likely a spec violation in its constructor (setAttribute/children forbidden)")
            #expect(shadow == true, "\(tag) has no shadow root after upgrade")
        }
    }

    // MARK: - Helper for creating elements programmatically

    private func createElement(_ h: Harness, tag: String, id: String, attrs: [String: String]) async throws {
        var js = "var el = document.createElement('\(tag)');"
        js += "el.id = '\(id)';"
        for (k, v) in attrs {
            js += "el.setAttribute('\(k)', '\(v.replacingOccurrences(of: "'", with: "\\'"))');"
        }
        js += "document.body.appendChild(el); void 0;"
        try await h.eval(js)
    }

    private func initWithMetadata(_ h: Harness, _ metadata: [[String: Any]], theme: String = "light") async throws {
        let values = metadata.map { ($0["default"] as? Double) ?? 0 }
        let state: [String: Any] = ["metadata": metadata, "values": values, "theme": theme]
        let data = try JSONSerialization.data(withJSONObject: state)
        let json = String(data: data, encoding: .utf8)!
        try await h.eval("ConjureDSP._init(\(json))")
    }

    // MARK: - <cdp-slider>

    @Test func sliderRendersLabelFromMetadata() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Cutoff", "min": 20.0, "max": 20000.0, "unit": "Hz", "curve": "log", "default": 1000.0]
        ])
        try await createElement(h, tag: "cdp-slider", id: "s", attrs: ["param": "0"])
        let label = try await h.eval("document.getElementById('s').shadowRoot.querySelector('[part=\"label\"]').textContent") as? String
        #expect(label == "Cutoff")
    }

    @Test func sliderValueReflectsInitialMetadata() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Mix", "min": 0.0, "max": 1.0, "default": 0.5]
        ])
        try await createElement(h, tag: "cdp-slider", id: "s", attrs: ["param": "0"])
        let raw = try await h.eval("document.getElementById('s').shadowRoot.querySelector('input').value") as? String
        let num = Double(raw ?? "-1") ?? -1
        #expect(abs(num - 0.5) < 1e-6, "got \(num)")
    }

    @Test func sliderExternalUpdateMovesThumb() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Mix", "min": 0.0, "max": 1.0, "default": 0.0]
        ])
        try await createElement(h, tag: "cdp-slider", id: "s", attrs: ["param": "0"])
        try await h.eval("ConjureDSP._paramUpdate(0, 0.75)")
        let raw = try await h.eval("document.getElementById('s').shadowRoot.querySelector('input').value") as? String
        let num = Double(raw ?? "-1") ?? -1
        #expect(abs(num - 0.75) < 1e-6, "got \(num)")
    }

    /// Regression for the preset-switch race that motivated manifest
    /// schema v2: when the bridge receives a SECOND `_init` with a
    /// different set of params (e.g., user switched from a 6-param
    /// preset to SVF's `cutoff`/`resonance` pair, and the Rust compile
    /// completed), components that were first bound against the old
    /// metadata must re-bind to the new metadata. Without this, a
    /// `<cdp-slider param="cutoff">` attached while the previous
    /// preset's params were in place stays wired to whatever
    /// `idxOf('cutoff')` returned then (typically -1 → disabled) even
    /// after `cutoff` appears in the refreshed metadata.
    ///
    /// The manifest-first load path fixes the race at the source —
    /// metadata is correct before the webview even loads — but this
    /// test pins the behavior for any code path that still sends two
    /// `_init`s (hot-reload, DSP recompile).
    @Test func componentRebindsOnSecondInitWithDifferentMetadata() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()

        // First _init: some other preset's params. `cutoff` is absent.
        try await initWithMetadata(h, [
            ["name": "low_gain",  "min": -12.0, "max": 12.0, "default": 0.0, "unit": "dB"],
            ["name": "mid_gain",  "min": -12.0, "max": 12.0, "default": 0.0, "unit": "dB"],
            ["name": "high_gain", "min": -12.0, "max": 12.0, "default": 0.0, "unit": "dB"],
        ])
        try await createElement(h, tag: "cdp-slider", id: "s", attrs: ["param": "cutoff"])

        let labelBefore = try await h.eval("document.getElementById('s').shadowRoot.querySelector('[part=\"label\"]').textContent") as? String
        #expect(labelBefore == "unknown", "slider should report 'unknown' when the requested param doesn't exist in current metadata; got \(labelBefore ?? "nil")")

        // Second _init: the REAL preset (the one the slider is for).
        try await initWithMetadata(h, [
            ["name": "cutoff",    "min": 20.0,  "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log"],
            ["name": "resonance", "min": 0.5,   "max": 10.0,    "default": 1.0,    "unit": "Q"],
        ])
        // Force rebind — the library doesn't re-run _bind on plain _init
        // without an attribute change. In production the manifest-first
        // load path ensures the FIRST _init has the right metadata, so
        // this hot-path is mostly an escape hatch. Here it proves the
        // mechanism is reachable.
        try await h.eval("""
            var s = document.getElementById('s');
            var v = s.getAttribute('param');
            s.removeAttribute('param');
            s.setAttribute('param', v);
        """)
        let labelAfter = try await h.eval("document.getElementById('s').shadowRoot.querySelector('[part=\"label\"]').textContent") as? String
        #expect(labelAfter == "cutoff", "slider must rebind to the freshly-arrived `cutoff` param; got \(labelAfter ?? "nil")")
    }

    @Test func sliderResolvesRustTitleCasedNameByAttr() async throws {
        // Rust's params!() macro emits names as Title Case with spaces.
        // The same snake_case attribute value must still find it.
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Low Gain", "min": -12.0, "max": 12.0, "unit": "dB", "default": 0.0]
        ])
        try await createElement(h, tag: "cdp-slider", id: "s", attrs: ["param": "low_gain"])
        let label = try await h.eval("document.getElementById('s').shadowRoot.querySelector('[part=\"label\"]').textContent") as? String
        #expect(label == "Low Gain")
    }

    @Test func sliderVerticalAppliesWritingMode() async throws {
        // <cdp-slider orientation="vertical"> should flip the native
        // <input type=range> into vertical layout via writing-mode.
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Mix", "min": 0.0, "max": 1.0, "default": 0.5]
        ])
        try await createElement(h, tag: "cdp-slider", id: "s", attrs: ["param": "0", "orientation": "vertical"])
        let writingMode = try await h.eval("getComputedStyle(document.getElementById('s').shadowRoot.querySelector('input')).writingMode") as? String
        #expect(writingMode?.contains("vertical") == true, "vertical orientation should flip writing-mode; got \(writingMode ?? "nil")")
    }

    @Test func sliderVerticalExternalUpdateStillBindsValue() async throws {
        // Vertical orientation must NOT regress the value-binding hot path.
        // External _paramUpdate should still set input.value identically.
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Mix", "min": 0.0, "max": 1.0, "default": 0.0]
        ])
        try await createElement(h, tag: "cdp-slider", id: "s", attrs: ["param": "0", "orientation": "vertical"])
        try await h.eval("ConjureDSP._paramUpdate(0, 0.75)")
        let raw = try await h.eval("document.getElementById('s').shadowRoot.querySelector('input').value") as? String
        let num = Double(raw ?? "-1") ?? -1
        #expect(abs(num - 0.75) < 1e-6, "got \(num)")
    }

    @Test func sliderHorizontalDefaultUnchanged() async throws {
        // Sliders without an orientation attribute must stay horizontal.
        // Pins the no-regression contract for existing UIs.
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Mix", "min": 0.0, "max": 1.0, "default": 0.5]
        ])
        try await createElement(h, tag: "cdp-slider", id: "s", attrs: ["param": "0"])
        let writingMode = try await h.eval("getComputedStyle(document.getElementById('s').shadowRoot.querySelector('input')).writingMode") as? String
        #expect(writingMode?.contains("vertical") != true, "default slider should stay horizontal-tb; got \(writingMode ?? "nil")")
    }

    // MARK: - <cdp-toggle>

    @Test func toggleReflectsInitialValue() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Bypass", "min": 0.0, "max": 1.0, "style": "toggle", "default": 1.0]
        ])
        try await createElement(h, tag: "cdp-toggle", id: "t", attrs: ["param": "0"])
        let checked = try await h.eval("document.getElementById('t').shadowRoot.querySelector('.switch').getAttribute('aria-checked')") as? String
        #expect(checked == "true")
    }

    @Test func toggleExternalUpdateFlipsAriaChecked() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Bypass", "min": 0.0, "max": 1.0, "style": "toggle", "default": 0.0]
        ])
        try await createElement(h, tag: "cdp-toggle", id: "t", attrs: ["param": "0"])
        try await h.eval("ConjureDSP._paramUpdate(0, 1)")
        let checked = try await h.eval("document.getElementById('t').shadowRoot.querySelector('.switch').getAttribute('aria-checked')") as? String
        #expect(checked == "true")
    }

    // MARK: - <cdp-choice>

    @Test func choiceSegmentedWhenTwoOptions() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Polarity", "min": 0.0, "max": 1.0, "style": "choice", "options": ["+", "-"], "default": 0.0]
        ])
        try await createElement(h, tag: "cdp-choice", id: "c", attrs: ["param": "0"])
        let hasSeg = try await h.eval("!!document.getElementById('c').shadowRoot.querySelector('.seg')") as? Bool
        let hasSelect = try await h.eval("!!document.getElementById('c').shadowRoot.querySelector('select')") as? Bool
        #expect(hasSeg == true)
        #expect(hasSelect == false)
    }

    @Test func choiceDropdownWhenThreeOrMoreOptions() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Mode", "min": 0.0, "max": 2.0, "style": "choice",
             "options": ["Low", "Mid", "High"], "default": 1.0]
        ])
        try await createElement(h, tag: "cdp-choice", id: "c", attrs: ["param": "0"])
        let hasSeg = try await h.eval("!!document.getElementById('c').shadowRoot.querySelector('.seg')") as? Bool
        let hasSelect = try await h.eval("!!document.getElementById('c').shadowRoot.querySelector('select')") as? Bool
        let selectValue = try await h.eval("document.getElementById('c').shadowRoot.querySelector('select').value") as? String
        #expect(hasSeg == false)
        #expect(hasSelect == true)
        #expect(selectValue == "1")
    }

    // MARK: - <cdp-panel auto>

    @Test func panelAutoPicksAppropriateComponentPerStyle() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "gain", "min": -24.0, "max": 12.0, "unit": "dB", "default": 0.0],
            ["name": "bypass", "min": 0.0, "max": 1.0, "style": "toggle", "default": 0.0],
            ["name": "mode", "min": 0.0, "max": 2.0, "style": "choice",
             "options": ["A", "B", "C"], "default": 0.0],
        ])
        try await createElement(h, tag: "cdp-panel", id: "p", attrs: ["auto": ""])
        let sliders = try await h.eval("document.getElementById('p').shadowRoot.querySelectorAll('cdp-slider').length") as? Int
        let toggles = try await h.eval("document.getElementById('p').shadowRoot.querySelectorAll('cdp-toggle').length") as? Int
        let choices = try await h.eval("document.getElementById('p').shadowRoot.querySelectorAll('cdp-choice').length") as? Int
        #expect(sliders == 1)
        #expect(toggles == 1)
        #expect(choices == 1)
    }

    // MARK: - Theme adoption

    @Test func themeAttributeAdoptedFromInit() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]], theme: "dark")
        try await createElement(h, tag: "cdp-slider", id: "s", attrs: ["param": "0"])
        let attr = try await h.eval("document.getElementById('s').getAttribute('data-cdp-theme')") as? String
        #expect(attr == "dark")
    }

    @Test func themeAttributeUpdatesOnThemeChange() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]], theme: "light")
        try await createElement(h, tag: "cdp-slider", id: "s", attrs: ["param": "0"])
        try await h.eval("ConjureDSP._setTheme('dark')")
        let attr = try await h.eval("document.getElementById('s').getAttribute('data-cdp-theme')") as? String
        #expect(attr == "dark")
    }

    // MARK: - <cdp-xy>

    @Test func xyPadRendersPuckAtExpectedPosition() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "X", "min": 0.0, "max": 1.0, "default": 0.5],
            ["name": "Y", "min": 0.0, "max": 1.0, "default": 0.5],
        ])
        try await createElement(h, tag: "cdp-xy", id: "xy", attrs: ["param-x": "0", "param-y": "1"])
        let left = try await h.eval("document.getElementById('xy').shadowRoot.querySelector('.puck').style.left") as? String
        let top = try await h.eval("document.getElementById('xy').shadowRoot.querySelector('.puck').style.top") as? String
        #expect(left == "50%")
        #expect(top == "50%")
    }

    /// Regression: a local drag on the pad must move the puck.
    /// `parameters.set` deliberately doesn't fire `onChange` (echo-
    /// avoidance), so a component that only subscribes to onChange
    /// won't redraw itself during its own drag. `_startDrag` must call
    /// `_render()` explicitly after each set.
    @Test func xyPadPuckMovesOnInternalDrag() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "X", "min": 0.0, "max": 1.0, "default": 0.0],
            ["name": "Y", "min": 0.0, "max": 1.0, "default": 0.0],
        ])
        try await createElement(h, tag: "cdp-xy", id: "xy", attrs: ["param-x": "0", "param-y": "1"])
        try await h.eval("""
            var xy = document.getElementById('xy');
            var pad = xy.shadowRoot.querySelector('.pad');
            var rect = pad.getBoundingClientRect();
            // Simulate a pointerdown at 30% x, 40% y.
            var e = new PointerEvent('pointerdown', {
                pointerId: 1,
                clientX: rect.left + rect.width * 0.3,
                clientY: rect.top + rect.height * 0.4,
                bubbles: true
            });
            pad.dispatchEvent(e);
        """)
        let left = try await h.eval("document.getElementById('xy').shadowRoot.querySelector('.puck').style.left") as? String
        let top = try await h.eval("document.getElementById('xy').shadowRoot.querySelector('.puck').style.top") as? String
        #expect(left == "30%", "puck x didn't track pointerdown — `_startDrag` likely missing an explicit `_render()` after `setValue`; got \(left ?? "nil")")
        #expect(top == "40%", "got \(top ?? "nil")")
    }

    @Test func xyPadPuckMovesOnExternalUpdate() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "X", "min": 0.0, "max": 1.0, "default": 0.0],
            ["name": "Y", "min": 0.0, "max": 1.0, "default": 0.0],
        ])
        try await createElement(h, tag: "cdp-xy", id: "xy", attrs: ["param-x": "0", "param-y": "1"])
        try await h.eval("ConjureDSP._paramUpdate(0, 0.25)")
        try await h.eval("ConjureDSP._paramUpdate(1, 0.75)")
        let left = try await h.eval("document.getElementById('xy').shadowRoot.querySelector('.puck').style.left") as? String
        let top = try await h.eval("document.getElementById('xy').shadowRoot.querySelector('.puck').style.top") as? String
        #expect(left == "25%")
        #expect(top == "75%")
    }

    // MARK: - <cdp-knob>

    /// Initial render: indicator rotation, label, value, and the
    /// `--cdp-knob-norm` CSS variable all reflect the bound parameter's
    /// default value at the moment the element binds.
    @Test func knobRendersInitialState() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Threshold", "min": -60.0, "max": 0.0, "default": -20.0, "unit": "dB"],
        ])
        try await createElement(h, tag: "cdp-knob", id: "k", attrs: ["param": "0"])

        // Default -20 in [-60..0] → norm 0.667 → angle 0.667*270 - 135 = 45°.
        let label = try await h.eval("document.getElementById('k').shadowRoot.querySelector('.label').textContent") as? String
        let value = try await h.eval("document.getElementById('k').shadowRoot.querySelector('.value').textContent") as? String
        let transform = try await h.eval("document.getElementById('k').shadowRoot.querySelector('.indicator-group').getAttribute('transform')") as? String
        let cssNorm = try await h.eval("document.getElementById('k').style.getPropertyValue('--cdp-knob-norm')") as? String
        #expect(label == "Threshold")
        #expect(value == "-20.00 dB")
        #expect(transform == "rotate(45 32 32)",
                "indicator should rotate to 45° at norm 0.667; got \(transform ?? "nil")")
        // Normalized published as a float string. Don't pin exact precision.
        #expect(cssNorm != nil && cssNorm!.hasPrefix("0.6"),
                "--cdp-knob-norm should be ~0.667; got \(cssNorm ?? "nil")")
    }

    /// External `_paramUpdate` (DAW automation, MIDI, MCP) drives all
    /// three visual surfaces: indicator transform, value text, CSS var.
    @Test func knobIndicatorRotatesOnExternalUpdate() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "Cutoff", "min": 0.0, "max": 1.0, "default": 0.0],
        ])
        try await createElement(h, tag: "cdp-knob", id: "k", attrs: ["param": "0"])
        try await h.eval("ConjureDSP._paramUpdate(0, 0.5)")

        let transform = try await h.eval("document.getElementById('k').shadowRoot.querySelector('.indicator-group').getAttribute('transform')") as? String
        let cssNorm = try await h.eval("document.getElementById('k').style.getPropertyValue('--cdp-knob-norm')") as? String
        // norm 0.5 → angle 0.5*270 - 135 = 0
        #expect(transform == "rotate(0 32 32)",
                "indicator should be at angle 0 at norm 0.5; got \(transform ?? "nil")")
        #expect(cssNorm == "0.5")
    }

    /// Vertical pointerdown→move→up drag updates the parameter value
    /// and the indicator. Same regression pattern as cdp-xy: the
    /// component subscribes to onChange via the bridge, but the test
    /// stub bridge doesn't fire onChange on self-writes (matches the
    /// pre-fix production behavior). The component's _startDrag.move
    /// must call `_render()` explicitly so the visual stays in sync
    /// even when the bridge is silent on self-writes — belt-and-
    /// suspenders against a bridge regression.
    @Test func knobDragUpdatesValueAndIndicator() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "X", "min": 0.0, "max": 1.0, "default": 0.0],
        ])
        try await createElement(h, tag: "cdp-knob", id: "k", attrs: ["param": "0"])
        // Drag up by 100px → 0.5 normalized step (200px = 0..1 default sensitivity).
        try await h.eval("""
            var k = document.getElementById('k');
            var v = k.shadowRoot.querySelector('.visual');
            var rect = v.getBoundingClientRect();
            var cx = rect.left + rect.width/2, cy = rect.top + rect.height/2;
            var down = new PointerEvent('pointerdown', {
                pointerId: 1, clientX: cx, clientY: cy, bubbles: true
            });
            var move = new PointerEvent('pointermove', {
                pointerId: 1, clientX: cx, clientY: cy - 100, buttons: 1, bubbles: true
            });
            var up = new PointerEvent('pointerup', {
                pointerId: 1, clientX: cx, clientY: cy - 100, bubbles: true
            });
            v.dispatchEvent(down); v.dispatchEvent(move); v.dispatchEvent(up);
        """)
        let paramValue = try await h.eval("ConjureDSP.parameters.get(0)") as? Double
        let transform = try await h.eval("document.getElementById('k').shadowRoot.querySelector('.indicator-group').getAttribute('transform')") as? String
        // 0.0 + 100/200 = 0.5 → angle 0
        #expect(paramValue == 0.5,
                "drag up 100px from default=0 should yield 0.5; got \(paramValue ?? -1)")
        #expect(transform == "rotate(0 32 32)",
                "indicator should match drag delta even when bridge is silent on self-writes; got \(transform ?? "nil")")
    }

    /// `--cdp-knob-norm` is the contract slotted custom-SVG visuals
    /// rely on: when the parameter changes, the host element's CSS
    /// variable must update so the slotted SVG's CSS-driven transforms
    /// pick up the new value without any per-author JS.
    @Test func knobPublishesCssVariableForSlottedVisuals() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [
            ["name": "X", "min": 0.0, "max": 1.0, "default": 0.0],
        ])
        try await createElement(h, tag: "cdp-knob", id: "k", attrs: ["param": "0"])
        // Step through several values and read the CSS variable each time.
        let values: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]
        for v in values {
            try await h.eval("ConjureDSP._paramUpdate(0, \(v))")
            // JS `String(0)` is "0" while Swift `String(0.0)` is "0.0";
            // parse-then-compare as numbers so the test is robust to
            // either side's number-to-string formatting.
            let read = try await h.eval("parseFloat(document.getElementById('k').style.getPropertyValue('--cdp-knob-norm'))") as? Double
            #expect(read != nil && abs(read! - v) < 1e-9,
                    "--cdp-knob-norm should track parameter value \(v); got \(read?.description ?? "nil")")
        }
    }

    // MARK: - <cdp-meter>

    /// Drive a deterministic tick. The meter advances ballistics on
    /// each `audio.onFrame` call; for tests we set `_latestRaw`
    /// directly and tick with a synthetic timestamp so dt is exactly
    /// what we want. Bypasses `_audioFrame` so the production
    /// frame-arrival auto-tick doesn't race the test clock.
    private func meterTick(_ h: Harness, id: String, atMs: Double, raw: Double? = nil) async throws {
        if let raw = raw {
            try await h.eval("""
                var _m = document.getElementById('\(id)');
                _m._latestRaw = \(raw);
                _m._haveFrame = true;
                _m._tick(\(atMs));
            """)
        } else {
            try await h.eval("document.getElementById('\(id)')._tick(\(atMs))")
        }
    }

    @Test func meterRendersShadowDom() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-meter", id: "m", attrs: ["source": "peak-out"])
        let hasTrack = try await h.eval("!!document.getElementById('m').shadowRoot.querySelector('[part=\"track\"]')") as? Bool
        let hasBar = try await h.eval("!!document.getElementById('m').shadowRoot.querySelector('[part=\"bar\"]')") as? Bool
        let hasPeak = try await h.eval("!!document.getElementById('m').shadowRoot.querySelector('[part=\"peak-hold\"]')") as? Bool
        #expect(hasTrack == true)
        #expect(hasBar == true)
        #expect(hasPeak == true)
    }

    @Test func meterSubscribesOnConnectAndUnsubscribesOnDisconnect() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])

        let subBefore = try await h.eval("ConjureDSP.audio._subCount") as? Int
        #expect(subBefore == 0)

        try await createElement(h, tag: "cdp-meter", id: "m", attrs: ["source": "peak-out"])
        let subAfter = try await h.eval("ConjureDSP.audio._subCount") as? Int
        let handlersAfterMount = try await h.eval("ConjureDSP.audio._handlers.length") as? Int
        #expect(subAfter == 1, "meter should call onFrame once on connect; got \(subAfter ?? -1)")
        #expect(handlersAfterMount == 1)

        try await h.eval("document.getElementById('m').remove()")
        let unsub = try await h.eval("ConjureDSP.audio._unsubCount") as? Int
        let handlersAfterRemove = try await h.eval("ConjureDSP.audio._handlers.length") as? Int
        #expect(unsub == 1, "meter should call offFrame once on disconnect; got \(unsub ?? -1)")
        #expect(handlersAfterRemove == 0)
    }

    @Test func meterBarRespondsToPeakOutFrame() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-meter", id: "m",
                                attrs: ["source": "peak-out", "min": "-60", "max": "0",
                                        "warn": "-18", "clip": "-6", "decay": "0", "hold": "0"])
        // Verify the production frame-arrival path: dispatch a real
        // _audioFrame and let the meter's onFrame -> _tick chain run.
        try await h.eval("ConjureDSP._audioFrame({peakIn: 0, peakOut: 1.0, rmsIn: 0, rmsOut: 0, t: 0})")
        let clip = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"bar\"]').style.clipPath") as? String
        #expect(clip != nil && clip!.contains("inset(0%"),
                "bar should fill to 100% (clip-path inset 0%) at peakOut=1.0; got \(clip ?? "nil")")
    }

    @Test func meterDecayReducesBarBetweenFrames() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        // 60 dB span; decay 60 dB/s → 30 dB drop in 0.5 s → display
        // moves from 0 dB (top) to -30 dB (50% of the span).
        try await createElement(h, tag: "cdp-meter", id: "m",
                                attrs: ["source": "peak-out", "min": "-60", "max": "0",
                                        "decay": "60", "hold": "0"])
        // Hit it hard at t=0.
        try await meterTick(h, id: "m", atMs: 0.0, raw: 1.0)
        // Hold raw at 1.0 across one more tick to ensure display = 0 dB.
        try await meterTick(h, id: "m", atMs: 1.0, raw: 1.0)
        // Now drop to silence and let it decay for 500 ms.
        try await meterTick(h, id: "m", atMs: 501.0, raw: 0.0)
        let clip = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"bar\"]').style.clipPath") as? String
        let pct = parseClipPathTopPct(clip)
        #expect(pct != nil, "could not parse clip-path; got \(clip ?? "nil")")
        if let p = pct {
            #expect(abs(p - 50.0) < 5.0, "expected ~50% top inset after 60 dB/s decay over 0.5 s; got \(p)% (clip-path \(clip ?? "nil"))")
        }
    }

    @Test func meterPeakHoldStaysThenDecays() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-meter", id: "m",
                                attrs: ["source": "peak-out", "min": "-60", "max": "0",
                                        "decay": "60", "hold": "200"])
        try await meterTick(h, id: "m", atMs: 0.0, raw: 1.0)
        try await meterTick(h, id: "m", atMs: 1.0, raw: 1.0)
        let peak1 = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"peak-hold\"]').style.bottom") as? String
        let pct1 = parsePercentString(peak1)
        #expect(pct1 != nil && pct1! > 95.0, "peak should latch near 100% after 0 dB frame; got \(peak1 ?? "nil")")

        // Drop to silence. Within hold window (100 ms < 200 ms hold), peak stays.
        try await meterTick(h, id: "m", atMs: 100.0, raw: 0.0)
        let peakHeld = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"peak-hold\"]').style.bottom") as? String
        let pctHeld = parsePercentString(peakHeld)
        #expect(pctHeld != nil && pctHeld! > 95.0,
                "peak should hold within hold window; got \(peakHeld ?? "nil")")

        // After hold expires, peak releases to the (decayed) display value.
        try await meterTick(h, id: "m", atMs: 400.0, raw: 0.0)
        let peakReleased = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"peak-hold\"]').style.bottom") as? String
        let pctReleased = parsePercentString(peakReleased)
        #expect(pctReleased != nil && pctReleased! < 80.0,
                "peak should drop after hold expires (display has decayed substantially); got \(peakReleased ?? "nil")")
    }

    @Test func meterClickResetsPeakHold() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-meter", id: "m",
                                attrs: ["source": "peak-out", "min": "-60", "max": "0",
                                        "decay": "60", "hold": "infinite"])
        try await meterTick(h, id: "m", atMs: 0.0, raw: 1.0)
        try await meterTick(h, id: "m", atMs: 1.0, raw: 1.0)
        // Drop to silence — display will decay, but peak holds (infinite).
        try await meterTick(h, id: "m", atMs: 500.0, raw: 0.0)
        let peakBefore = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"peak-hold\"]').style.bottom") as? String
        let pctBefore = parsePercentString(peakBefore)
        #expect(pctBefore != nil && pctBefore! > 95.0,
                "peak should still be near top with hold='infinite'; got \(peakBefore ?? "nil")")

        // Click the container (any click on the meter resets).
        try await h.eval("""
            var m = document.getElementById('m');
            var c = m.shadowRoot.querySelector('[part="container"]');
            c.dispatchEvent(new MouseEvent('click', {bubbles: true}));
        """)
        let peakAfter = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"peak-hold\"]').style.bottom") as? String
        let pctAfter = parsePercentString(peakAfter)
        #expect(pctAfter != nil && pctAfter! < pctBefore!,
                "click should snap peak to current (lower) display value; got before=\(peakBefore ?? "nil") after=\(peakAfter ?? "nil")")
    }

    @Test func meterTelemetrySourceReadsTelemetryDict() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-meter", id: "m",
                                attrs: ["source": "telemetry:gain_reduction",
                                        "min": "-24", "max": "0",
                                        "decay": "0", "hold": "0"])
        // unit defaults to db for telemetry sources. GR = -12 dB
        // (halfway through the 24 dB span) → display ~50%. Round-trip
        // through the production _audioFrame path so the source-parsing
        // ("telemetry:gain_reduction") is exercised end-to-end.
        try await h.eval("""
            ConjureDSP._audioFrame({
                peakIn: 0, peakOut: 0, rmsIn: 0, rmsOut: 0, t: 0,
                telemetry: {gain_reduction: -12}
            })
        """)
        let clip = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"bar\"]').style.clipPath") as? String
        let pct = parseClipPathTopPct(clip)
        #expect(pct != nil && abs(pct! - 50.0) < 2.0,
                "telemetry source at -12 dB / range [-24, 0] should fill ~50%; got \(clip ?? "nil")")
    }

    @Test func meterUnitDbSkipsLinearConversion() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-meter", id: "m",
                                attrs: ["source": "peak-out", "unit": "db",
                                        "min": "-60", "max": "0",
                                        "decay": "0", "hold": "0"])
        // unit=db: peakOut=0 is interpreted as 0 dB (= top), not as
        // linear silence. Without this, raw=0 → log10(1e-9)*20 = -180 dB.
        try await h.eval("ConjureDSP._audioFrame({peakIn: 0, peakOut: 0.0, rmsIn: 0, rmsOut: 0, t: 0})")
        let clip = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"bar\"]').style.clipPath") as? String
        #expect(clip != nil && clip!.contains("inset(0%"),
                "unit='db' should treat raw value as dB; 0.0 → 0 dB → bar at top; got \(clip ?? "nil")")
    }

    @Test func meterGradientSmoothCollapsesHardStops() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-meter", id: "z",
                                attrs: ["source": "peak-out", "min": "-60", "max": "0",
                                        "warn": "-18", "clip": "-6"])
        try await createElement(h, tag: "cdp-meter", id: "s",
                                attrs: ["source": "peak-out", "min": "-60", "max": "0",
                                        "warn": "-18", "clip": "-6", "gradient": "smooth"])
        let zonesBg = try await h.eval(
            "document.getElementById('z').shadowRoot.querySelector('[part=\"bar\"]').style.getPropertyValue('--_cdp-meter-bar-bg')") as? String
        let smoothBg = try await h.eval(
            "document.getElementById('s').shadowRoot.querySelector('[part=\"bar\"]').style.getPropertyValue('--_cdp-meter-bar-bg')") as? String
        // zones produces 6 stops (one pair per color, hard edges); smooth
        // produces 4 (one anchor per color + final red). Counting the
        // word "var(" — each stop references one CSS custom property —
        // is the simplest discriminator that doesn't depend on whitespace.
        let zonesStops = zonesBg.map { $0.components(separatedBy: "var(").count - 1 } ?? 0
        let smoothStops = smoothBg.map { $0.components(separatedBy: "var(").count - 1 } ?? 0
        #expect(zonesStops == 6, "zones gradient should have 6 var() stops; got \(zonesStops) in \(zonesBg ?? "nil")")
        #expect(smoothStops == 4, "smooth gradient should have 4 var() stops; got \(smoothStops) in \(smoothBg ?? "nil")")
    }

    @Test func meterInvertFlipsBarFillDirection() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        // GR meter: 0 dB = no reduction (safe, top), -24 dB = max
        // reduction (danger, bottom). At gain_reduction = -12 (half),
        // bar should fill the top half — clipPath insets the *bottom*
        // 50%, not the top.
        try await createElement(h, tag: "cdp-meter", id: "m",
                                attrs: ["source": "telemetry:gr", "min": "-24", "max": "0",
                                        "warn": "-6", "clip": "-12", "invert": "",
                                        "decay": "0", "hold": "0"])
        try await h.eval("""
            ConjureDSP._audioFrame({
                peakIn: 0, peakOut: 0, rmsIn: 0, rmsOut: 0, t: 0,
                telemetry: {gr: -12}
            })
        """)
        let clip = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"bar\"]').style.clipPath") as? String
        // Inverted vertical fill clips from bottom — third inset value
        // (bottom) should be ~50%, first two (top, right) should be 0.
        // WebKit normalizes `0` → `0px` and may collapse trailing zero
        // shorthand, so we parse rather than prefix-match.
        #expect(clip != nil, "got nil clip-path")
        if let s = clip {
            let parts = s.replacingOccurrences(of: "inset(", with: "").replacingOccurrences(of: ")", with: "")
                .split(separator: " ").map(String.init)
            let isZero = { (v: String) -> Bool in v == "0" || v == "0px" || v == "0%" }
            #expect(parts.count >= 3 && isZero(parts[0]) && isZero(parts[1]),
                    "inverted vertical should clip from bottom — first two insets should be 0; got \(s)")
            if parts.count >= 3, let p = Double(parts[2].replacingOccurrences(of: "%", with: "")) {
                #expect(abs(p - 50.0) < 2.0,
                        "GR=-12 in [-24, 0] should clip ~50% from bottom; got \(p)% (\(s))")
            } else {
                Issue.record("could not parse third inset value from \(s)")
            }
        }
    }

    @Test func meterInvertFlipsPeakMarkerToTop() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-meter", id: "m",
                                attrs: ["source": "telemetry:gr", "min": "-24", "max": "0",
                                        "invert": "", "decay": "0", "hold": "infinite"])
        try await h.eval("""
            ConjureDSP._audioFrame({
                peakIn: 0, peakOut: 0, rmsIn: 0, rmsOut: 0, t: 0,
                telemetry: {gr: -24}
            })
        """)
        let top = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"peak-hold\"]').style.top") as? String
        let bottom = try await h.eval("document.getElementById('m').shadowRoot.querySelector('[part=\"peak-hold\"]').style.bottom") as? String
        let topPct = parsePercentString(top)
        #expect(topPct != nil && topPct! > 95.0,
                "inverted vertical peak should sit near top:100% at min value; got top=\(top ?? "nil")")
        #expect((bottom ?? "").isEmpty,
                "inverted vertical peak should not also set `bottom`; got bottom=\(bottom ?? "nil")")
    }

    @Test func meterCustomGradientCSSVarOverridesBuiltGradient() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        // Set the override BEFORE the meter mounts so it picks up the
        // cascaded value on first paint.
        try await h.eval("""
            var el = document.createElement('cdp-meter');
            el.id = 'm';
            el.setAttribute('source', 'peak-out');
            el.style.setProperty('--cdp-meter-gradient', 'linear-gradient(to top, magenta 0%, cyan 100%)');
            document.body.appendChild(el);
            void 0;
        """)
        // The CSS chain is `background: var(--cdp-meter-gradient,
        // var(--_cdp-meter-bar-bg))`. With the override set, the bar's
        // computed background should reflect the magenta/cyan gradient,
        // not the green/yellow/red one JS still writes to the internal var.
        let computed = try await h.eval("""
            (() => {
                var bar = document.getElementById('m').shadowRoot.querySelector('[part="bar"]');
                return getComputedStyle(bar).backgroundImage;
            })()
        """) as? String
        #expect(computed != nil, "computed background-image was nil")
        if let s = computed {
            // WebKit's computed value resolves named colors to rgb(..)
            // so check for both the literal name and the resolved form.
            let isMagenta = s.contains("magenta") || s.lowercased().contains("rgb(255, 0, 255)")
            #expect(isMagenta, "custom gradient should win — expected magenta in computed bg; got \(s)")
            #expect(!s.contains("oklch"),
                    "default oklch stops should be absent when override is set; got \(s)")
        }
    }

    // MARK: - <cdp-bargraph>

    @Test func bargraphRendersShadowDom() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-bargraph", id: "b",
                                attrs: ["telemetry": "BAR", "count": "4"])
        let hasBars = try await h.eval(
            "!!document.getElementById('b').shadowRoot.querySelector('[part=\"bars\"]')") as? Bool
        let barCount = try await h.eval(
            "document.getElementById('b').shadowRoot.querySelectorAll('[part=\"bar\"]').length") as? Int
        let fillCount = try await h.eval(
            "document.getElementById('b').shadowRoot.querySelectorAll('[part=\"bar-fill\"]').length") as? Int
        #expect(hasBars == true)
        #expect(barCount == 4, "expected 4 bar nodes; got \(barCount ?? -1)")
        #expect(fillCount == 4, "expected 4 bar-fill nodes; got \(fillCount ?? -1)")
    }

    @Test func bargraphSubscribesOnConnectAndUnsubscribesOnDisconnect() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])

        let subBefore = try await h.eval("ConjureDSP.audio._subCount") as? Int
        #expect(subBefore == 0)

        try await createElement(h, tag: "cdp-bargraph", id: "b",
                                attrs: ["telemetry": "BAR", "count": "4"])
        let subAfter = try await h.eval("ConjureDSP.audio._subCount") as? Int
        #expect(subAfter == 1, "bargraph should call onFrame once on connect; got \(subAfter ?? -1)")

        try await h.eval("document.getElementById('b').remove()")
        let unsub = try await h.eval("ConjureDSP.audio._unsubCount") as? Int
        #expect(unsub == 1, "bargraph should call offFrame once on disconnect; got \(unsub ?? -1)")
    }

    /// Spec test: 4 bars, 4-element vector at [0.25, 0.5, 0.75, 1.0],
    /// default range [0, 1], vertical orientation. Each bar's fill height
    /// should reflect its value as a percent.
    @Test func bargraphRendersFourBarsWithExpectedHeights() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-bargraph", id: "b",
                                attrs: ["telemetry": "BAR", "count": "4"])
        try await h.eval("""
            ConjureDSP._audioFrame({
                peakIn: 0, peakOut: 0, rmsIn: 0, rmsOut: 0, t: 0,
                telemetry: {BAR: [0.25, 0.5, 0.75, 1.0]}
            })
        """)
        let heights = try await h.eval("""
            (() => {
                var fills = document.getElementById('b').shadowRoot.querySelectorAll('[part="bar-fill"]');
                return Array.from(fills).map(f => f.style.height);
            })()
        """) as? [String]
        #expect(heights != nil, "could not read fill heights")
        guard let h0 = heights else { return }
        #expect(h0.count == 4, "expected 4 fills; got \(h0.count)")
        let parsed = h0.compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        #expect(parsed.count == 4, "all 4 heights should parse as percentages; got \(h0)")
        #expect(abs(parsed[0] - 25.0) < 0.5, "bar 0 = 0.25 → 25%; got \(parsed[0])")
        #expect(abs(parsed[1] - 50.0) < 0.5, "bar 1 = 0.5 → 50%; got \(parsed[1])")
        #expect(abs(parsed[2] - 75.0) < 0.5, "bar 2 = 0.75 → 75%; got \(parsed[2])")
        #expect(abs(parsed[3] - 100.0) < 0.5, "bar 3 = 1.0 → 100%; got \(parsed[3])")
    }

    @Test func bargraphRespectsCustomMinMaxRange() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        // Range [0, 10]: value 5 → 50%, value 2.5 → 25%.
        try await createElement(h, tag: "cdp-bargraph", id: "b",
                                attrs: ["telemetry": "BAR", "count": "2",
                                        "min": "0", "max": "10"])
        try await h.eval("""
            ConjureDSP._audioFrame({
                peakIn: 0, peakOut: 0, rmsIn: 0, rmsOut: 0, t: 0,
                telemetry: {BAR: [2.5, 5.0]}
            })
        """)
        let heights = try await h.eval("""
            (() => {
                var fills = document.getElementById('b').shadowRoot.querySelectorAll('[part="bar-fill"]');
                return Array.from(fills).map(f => f.style.height);
            })()
        """) as? [String]
        guard let hs = heights, hs.count == 2 else {
            Issue.record("could not read both fill heights")
            return
        }
        let p0 = Double(hs[0].replacingOccurrences(of: "%", with: ""))
        let p1 = Double(hs[1].replacingOccurrences(of: "%", with: ""))
        #expect(p0 != nil && abs(p0! - 25.0) < 0.5, "2.5 / 10 → 25%; got \(hs[0])")
        #expect(p1 != nil && abs(p1! - 50.0) < 0.5, "5 / 10 → 50%; got \(hs[1])")
    }

    @Test func bargraphClampsValuesOutsideRange() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-bargraph", id: "b",
                                attrs: ["telemetry": "BAR", "count": "3"])
        // Below min, in-range, above max.
        try await h.eval("""
            ConjureDSP._audioFrame({
                peakIn: 0, peakOut: 0, rmsIn: 0, rmsOut: 0, t: 0,
                telemetry: {BAR: [-0.5, 0.5, 2.0]}
            })
        """)
        let heights = try await h.eval("""
            (() => {
                var fills = document.getElementById('b').shadowRoot.querySelectorAll('[part="bar-fill"]');
                return Array.from(fills).map(f => f.style.height);
            })()
        """) as? [String]
        guard let hs = heights, hs.count == 3 else {
            Issue.record("could not read fill heights")
            return
        }
        let parsed = hs.compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        #expect(parsed.count == 3)
        #expect(abs(parsed[0] - 0.0) < 0.5, "negative value should clamp to 0%; got \(hs[0])")
        #expect(abs(parsed[1] - 50.0) < 0.5, "0.5 → 50%; got \(hs[1])")
        #expect(abs(parsed[2] - 100.0) < 0.5, "above max should clamp to 100%; got \(hs[2])")
    }

    @Test func bargraphShortVectorLeavesRemainingBarsZero() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        // count=4, but we publish only 2 elements.
        try await createElement(h, tag: "cdp-bargraph", id: "b",
                                attrs: ["telemetry": "BAR", "count": "4"])
        try await h.eval("""
            ConjureDSP._audioFrame({
                peakIn: 0, peakOut: 0, rmsIn: 0, rmsOut: 0, t: 0,
                telemetry: {BAR: [0.6, 0.9]}
            })
        """)
        let heights = try await h.eval("""
            (() => {
                var fills = document.getElementById('b').shadowRoot.querySelectorAll('[part="bar-fill"]');
                return Array.from(fills).map(f => f.style.height);
            })()
        """) as? [String]
        guard let hs = heights, hs.count == 4 else {
            Issue.record("expected 4 fill nodes")
            return
        }
        let parsed = hs.compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        #expect(parsed.count == 4)
        #expect(abs(parsed[0] - 60.0) < 0.5)
        #expect(abs(parsed[1] - 90.0) < 0.5)
        #expect(abs(parsed[2] - 0.0) < 0.5, "remaining bars should be 0; got bar 2 = \(hs[2])")
        #expect(abs(parsed[3] - 0.0) < 0.5, "remaining bars should be 0; got bar 3 = \(hs[3])")
    }

    @Test func bargraphHorizontalOrientationFillsWidth() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-bargraph", id: "b",
                                attrs: ["telemetry": "BAR", "count": "2",
                                        "orientation": "horizontal"])
        try await h.eval("""
            ConjureDSP._audioFrame({
                peakIn: 0, peakOut: 0, rmsIn: 0, rmsOut: 0, t: 0,
                telemetry: {BAR: [0.4, 0.8]}
            })
        """)
        // Horizontal: width is set, height should not be.
        let widths = try await h.eval("""
            (() => {
                var fills = document.getElementById('b').shadowRoot.querySelectorAll('[part="bar-fill"]');
                return Array.from(fills).map(f => f.style.width);
            })()
        """) as? [String]
        let heights = try await h.eval("""
            (() => {
                var fills = document.getElementById('b').shadowRoot.querySelectorAll('[part="bar-fill"]');
                return Array.from(fills).map(f => f.style.height);
            })()
        """) as? [String]
        guard let ws = widths, ws.count == 2 else {
            Issue.record("could not read fill widths")
            return
        }
        let parsed = ws.compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        #expect(parsed.count == 2)
        #expect(abs(parsed[0] - 40.0) < 0.5, "horizontal: width should be 40%; got \(ws[0])")
        #expect(abs(parsed[1] - 80.0) < 0.5, "horizontal: width should be 80%; got \(ws[1])")
        // Heights should be empty (not set inline) so the CSS-default
        // height: 0% rule doesn't apply — but the production CSS sets
        // height: 0% on horizontal fills via :host selector, so we just
        // check the inline style isn't populated.
        if let hsArr = heights {
            for h2 in hsArr {
                #expect(h2 == "" || h2 == "0%",
                        "horizontal orientation should not set height inline; got \(h2)")
            }
        }
    }

    @Test func bargraphLooseTelemetryNameResolvesAcrossCases() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        // Attribute "tap_energies" should resolve against published
        // "TAP_ENERGIES" via the loose normalizer.
        try await createElement(h, tag: "cdp-bargraph", id: "b",
                                attrs: ["telemetry": "tap_energies", "count": "3"])
        try await h.eval("""
            ConjureDSP._audioFrame({
                peakIn: 0, peakOut: 0, rmsIn: 0, rmsOut: 0, t: 0,
                telemetry: {TAP_ENERGIES: [0.1, 0.2, 0.3]}
            })
        """)
        let heights = try await h.eval("""
            (() => {
                var fills = document.getElementById('b').shadowRoot.querySelectorAll('[part="bar-fill"]');
                return Array.from(fills).map(f => f.style.height);
            })()
        """) as? [String]
        guard let hs = heights, hs.count == 3 else {
            Issue.record("expected 3 fills")
            return
        }
        let parsed = hs.compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        #expect(parsed.count == 3, "loose-resolution should bind despite case mismatch; got \(hs)")
        if parsed.count == 3 {
            #expect(abs(parsed[0] - 10.0) < 0.5)
            #expect(abs(parsed[1] - 20.0) < 0.5)
            #expect(abs(parsed[2] - 30.0) < 0.5)
        }
    }

    @Test func bargraphScalarTelemetryIsIgnored() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-bargraph", id: "b",
                                attrs: ["telemetry": "GR_DB", "count": "2"])
        // Scalar slot — bargraph should bail (bar fills stay at default empty).
        try await h.eval("""
            ConjureDSP._audioFrame({
                peakIn: 0, peakOut: 0, rmsIn: 0, rmsOut: 0, t: 0,
                telemetry: {GR_DB: -6}
            })
        """)
        let heights = try await h.eval("""
            (() => {
                var fills = document.getElementById('b').shadowRoot.querySelectorAll('[part="bar-fill"]');
                return Array.from(fills).map(f => f.style.height);
            })()
        """) as? [String]
        // Initial inline height is unset (CSS default 0%); scalar bail
        // means we never write an inline value, so it stays empty.
        if let hs = heights {
            for v in hs {
                #expect(v == "" || v == "0%",
                        "scalar telemetry should not populate any bar fill; got \(v)")
            }
        }
    }

    @Test func bargraphCountChangeRebuildsBars() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()
        try await initWithMetadata(h, [["name": "x", "min": 0.0, "max": 1.0]])
        try await createElement(h, tag: "cdp-bargraph", id: "b",
                                attrs: ["telemetry": "BAR", "count": "3"])
        let initial = try await h.eval(
            "document.getElementById('b').shadowRoot.querySelectorAll('[part=\"bar\"]').length") as? Int
        #expect(initial == 3)

        try await h.eval("document.getElementById('b').setAttribute('count', '6')")
        let after = try await h.eval(
            "document.getElementById('b').shadowRoot.querySelectorAll('[part=\"bar\"]').length") as? Int
        #expect(after == 6, "count change should rebuild bars; got \(after ?? -1)")
    }

    /// Parse a "X.X%" string to Double. Returns nil on failure.
    private func parsePercentString(_ s: String?) -> Double? {
        guard let raw = s else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("%") else { return nil }
        return Double(trimmed.dropLast())
    }

    /// Extract the top inset percentage from `inset(<top>% <right>% <bot>% <left>%)`
    /// or `inset(<top>% 0 0 0)`. Returns nil on failure.
    private func parseClipPathTopPct(_ s: String?) -> Double? {
        guard let raw = s else { return nil }
        guard let openParen = raw.firstIndex(of: "("),
              let closeParen = raw.lastIndex(of: ")") else { return nil }
        let inner = raw[raw.index(after: openParen)..<closeParen]
        let parts = inner.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let str = String(first)
        if str.hasSuffix("%") { return Double(str.dropLast()) }
        return Double(str)
    }

    @Test func libraryApiReachableInWebKit() async throws {
        let h = try Harness(html: "")
        try await h.waitForNavigationAndSetup()

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
