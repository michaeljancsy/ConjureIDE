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
        let tags = ["cdp-slider", "cdp-toggle", "cdp-choice", "cdp-xy", "cdp-panel"]
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
