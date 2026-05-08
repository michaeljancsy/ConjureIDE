import AppKit
import Foundation
import os
import WebKit

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "BundleUISmokeTester")

/// Runtime ("Tier 3") validator that loads a preset bundle's custom UI
/// in an offscreen WKWebView and reports on:
///
///   - Whether the bridge fired `ready` within the timeout window
///   - Any JavaScript errors / unhandled promise rejections / console.error
///     output produced during load
///   - Per-component binding status (did every `cdp-slider` /
///     `cdp-toggle` / `cdp-choice` / `cdp-xy` successfully resolve its
///     `param=` attribute against the host's parameter metadata?)
///   - Per-parameter coverage (does every declared param have at least
///     one component that's bound to it?)
///
/// The Tier 1 / Tier 2 static validator (`BundleUIValidator`) catches
/// everything that's knowable from the source text alone. This harness
/// catches the rest — the runtime-only failures where HTML looks
/// reasonable but the rendered webview is silently broken: JS throws
/// during init, shadow-DOM custom elements fail to upgrade because
/// `cdp-ui.js` can't parse them, `param=` references exist in the
/// manifest but don't resolve because of a case/underscore/space quirk
/// we didn't think of, or the UI has zero interactive elements bound
/// to any declared param.
///
/// Invoked via MCP's `smoke_test_ui` tool so the embedded agent can
/// call it after every `write_bundle_file` to ui/ and confirm the
/// edits actually work at runtime before declaring done.
///
/// Budget: ~3s per run (1.5s load, 0.5s ready handshake, 1s probe).
/// Runs fully async on the main actor — the WKWebView lifecycle and
/// window management have to live there anyway.
@MainActor
final class BundleUISmokeTester: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    // MARK: - Public entry point

    /// Run the smoke test against `bundle` and return a structured
    /// report. Completes within `timeout` seconds regardless of whether
    /// the UI actually reaches a steady state — that's the point of a
    /// smoke test: if `ready` doesn't fire in time, that's itself a
    /// failure the caller wants to know about.
    static func run(
        bundle: PresetBundle,
        hostParameterNames: [Int: String],
        hostParameterCount: Int,
        timeout: TimeInterval = 3.0,
        resourceBundle: Bundle? = nil,
        declaredStateKeys: [String] = []
    ) async -> Report {
        let tester = BundleUISmokeTester()
        tester.resourceBundle = resourceBundle ?? Bundle(for: BundleUISmokeTester.self)
        tester.declaredStateKeys = declaredStateKeys
        return await withCheckedContinuation { cont in
            tester.start(
                bundle: bundle,
                hostParameterNames: hostParameterNames,
                hostParameterCount: hostParameterCount,
                timeout: timeout
            ) { report in
                cont.resume(returning: report)
            }
        }
    }

    // MARK: - Report shape

    enum ReportStatus: String, Encodable {
        case pass   // ready fired, no JS errors, all components bound, every declared param covered
        case warn   // minor issues (e.g. declared param with no UI binding, but UI otherwise works)
        case fail   // ready didn't fire, JS errors, or unbound components
    }

    struct JSLogEntry: Encodable, Equatable {
        let kind: String          // "error", "unhandledrejection", "console.error", "console.warn"
        let message: String
        let atMs: Double          // performance.now() when captured

        enum CodingKeys: String, CodingKey {
            case kind, message
            case atMs = "at_ms"
        }
    }

    struct ComponentReport: Encodable, Equatable {
        let tag: String                   // "cdp-slider", "cdp-xy", ...
        let param: String?                // `param` attribute value, if any
        let paramX: String?               // `param-x` for cdp-xy
        let paramY: String?               // `param-y` for cdp-xy
        let bound: Bool
        let reason: String?               // why bound=false, when applicable

        enum CodingKeys: String, CodingKey {
            case tag, param
            case paramX = "param_x"
            case paramY = "param_y"
            case bound, reason
        }
    }

    struct ParamCoverage: Encodable, Equatable {
        let index: Int
        let name: String
        let hasInteractiveBinding: Bool
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case index, name
            case hasInteractiveBinding = "has_interactive_binding"
            case reason
        }
    }

    /// Reported when the rendered HTML's scroll extent exceeds the
    /// manifest's declared `ui.width` / `ui.height` by more than
    /// `overflowToleranceP`. Captures both the declared and rendered
    /// dimensions so the caller can see exactly how much to bump the
    /// manifest by — clipping silently in the live plugin (and in
    /// exported AUs that pin the webview to manifest dimensions) was
    /// invisible to the static validator. Omitted from the report
    /// entirely when the content fits.
    struct ContentOverflow: Encodable, Equatable {
        struct Size: Encodable, Equatable {
            let width: Int
            let height: Int
        }
        struct ByPixels: Encodable, Equatable {
            let width: Int?
            let height: Int?
        }
        let declared: Size
        let rendered: Size
        let overflows: [String]   // any subset of ["width", "height"]
        let byPixels: ByPixels

        enum CodingKeys: String, CodingKey {
            case declared, rendered, overflows
            case byPixels = "by_pixels"
        }
    }

    /// Pixel slack — render extents within this many pixels of the
    /// declared bounds are treated as fitting. WebKit's measured
    /// scroll dimensions can drift by a pixel or two from authored
    /// CSS due to subpixel rounding and font metrics; 8px gives plenty
    /// of headroom for that without masking the kind of overflow that
    /// shipped Round 8's Dyn EQ Triad ~75pt cramped.
    private static let overflowToleranceP: Int = 8

    /// One text element whose computed foreground/background contrast
    /// fell below the WCAG AA large-text threshold (3.0). Captured by
    /// the runtime probe — the static validator can't see this when
    /// the offending color comes from a `var(--cdp-...)` chain that
    /// terminates at `CanvasText` (a system color whose value depends
    /// on the runtime `color-scheme`). Caps at the first 10 to keep the
    /// report bounded for badly-themed UIs.
    struct TextContrastIssue: Encodable, Equatable {
        let selector: String
        let text: String          // first ~50 chars of the element's own text
        let foreground: String    // computed RGB / RGBA string
        let background: String    // effective background (walked up to the first opaque ancestor)
        let ratio: Double         // rounded to 2 decimals

        enum CodingKeys: String, CodingKey {
            case selector, text, foreground, background, ratio
        }
    }

    /// Cap on how many low-contrast text issues we serialize. A badly
    /// themed UI can have hundreds of children inheriting one bad rule;
    /// the first few are diagnostic, the rest are noise.
    private static let textContrastIssueCap: Int = 10

    /// Outcome of the bundle-private STATE channel probe. The smoke
    /// tester drives the JS bridge surface (`ConjureDSP.state.*`) only —
    /// there's no live kernel here, so we can't verify the audio side.
    /// What we CAN verify is:
    ///   - `state.get` returns something for the first declared key
    ///   - `state.set` returns true (sync size check passed)
    ///   - an `onChange` handler installed before the set fires once
    /// Skipped (`ran = false`) when the caller didn't supply any
    /// declared keys — there's nothing to probe.
    struct StateProbeResult: Encodable, Equatable {
        let ran: Bool
        let key: String?
        /// JSON-encoded value returned by `state.get(key)`. Stringified
        /// because the bridge may return objects/arrays/primitives — a
        /// JSON string is the most portable form for the Swift report.
        let getReturned: String?
        let setReturned: Bool?
        let onChangeFiredCount: Int
        let error: String?

        enum CodingKeys: String, CodingKey {
            case ran, key
            case getReturned = "get_returned"
            case setReturned = "set_returned"
            case onChangeFiredCount = "on_change_fired_count"
            case error
        }
    }

    struct SmallControl: Encodable, Equatable {
        let tag: String
        let param: String?
        let width: Double
        let height: Double
        let reason: String?
        let detail: String?

        enum CodingKeys: String, CodingKey {
            case tag, param, width, height, reason, detail
        }
    }

    struct CanvasIssue: Encodable, Equatable {
        let id: String
        let layout: [Double]
        let buffer: [Double]
        let reason: String
        let hint: String

        enum CodingKeys: String, CodingKey {
            case id, layout, buffer, reason, hint
        }
    }

    /// Soft layout observations grouped together so they don't read as
    /// hard warnings at `status: pass`. The numeric ratios + per-cell
    /// coverage are still useful diagnostics for an agent that cares,
    /// but moving them off the top level keeps a clean pass response
    /// from carrying items shaped like problems. `flags` captures the
    /// soft heuristics (`sparse`, `clustered`, `empty_region`) — hard
    /// runtime issues like canvas zero-buffer surface separately
    /// through `canvas_issues`.
    ///
    /// Populated only when `ready` fired AND there's actual layout data
    /// to summarize (i.e. at least one interactive control was measured
    /// on a canvas big enough for the heuristics to mean anything).
    /// Absent otherwise.
    struct LayoutAdvisory: Encodable, Equatable {
        let coverageRatio: Double
        let bboxRatio: Double
        let cellCoverage: [[Double]]
        let flags: [String]

        enum CodingKeys: String, CodingKey {
            case coverageRatio = "coverage_ratio"
            case bboxRatio = "bbox_ratio"
            case cellCoverage = "cell_coverage"
            case flags
        }
    }

    struct Report: Encodable {
        let status: ReportStatus
        let readyFired: Bool
        let readyTimeMs: Double?          // time from load to `ready`, nil if it didn't fire
        let loadError: String?            // WKNavigationDelegate didFail*
        let jsErrors: [JSLogEntry]
        let consoleLogs: [String]
        let components: [ComponentReport]
        let params: [ParamCoverage]
        let contentOverflow: ContentOverflow?
        let lowContrastTexts: [TextContrastIssue]
        let stateProbe: StateProbeResult?
        let smallControls: [SmallControl]
        let layoutAdvisory: LayoutAdvisory?
        let canvasIssues: [CanvasIssue]

        enum CodingKeys: String, CodingKey {
            case status
            case readyFired = "ready_fired"
            case readyTimeMs = "ready_time_ms"
            case loadError = "load_error"
            case jsErrors = "js_errors"
            case consoleLogs = "console_logs"
            case components
            case params
            case contentOverflow = "content_overflow"
            case lowContrastTexts = "low_contrast_texts"
            case stateProbe = "state_probe"
            case smallControls = "small_controls"
            case layoutAdvisory = "layout_advisory"
            case canvasIssues = "canvas_issues"
        }
    }

    // MARK: - Private state

    private var webView: WKWebView?
    private var schemeHandler: BundleAssetSchemeHandler?
    /// Per-tester unique scheme name (see start() for rationale).
    /// Seeded in `start()`; default kept for safety before start runs.
    private var customScheme: String = "conjuredsp-preset"
    private var completion: ((Report) -> Void)?
    private var didComplete = false
    private var loadStart: TimeInterval = 0
    private var readyAtMs: Double?
    private var loadError: String?
    private var hostParameterNames: [Int: String] = [:]
    private var hostParameterCount: Int = 0
    /// Manifest-declared UI dimensions in points. Used both to size the
    /// offscreen WKWebView (so layout matches what the live plugin / a
    /// future export would render) and to compare against the post-load
    /// scroll extent for overflow detection.
    private var declaredWidth: Int = 0
    private var declaredHeight: Int = 0
    private var timeoutTask: DispatchWorkItem?
    /// Messages posted through the bridge's `log` channel. The bridge
    /// funnels user-callback exceptions through here via `safeInvoke`,
    /// so anything landing in this list is either author debug output
    /// or a caught-and-reformatted error.
    private var bridgeLogs: [(String, Double)] = []
    private var consoleLogs: [String] = []
    /// Where to look for `customui-bridge.js` + `cdp-ui.js`. In
    /// production this is the extension's own bundle (via
    /// `Bundle(for: Self.self)`). Tests override with the appex's
    /// Resources bundle since the test target doesn't include them.
    fileprivate var resourceBundle: Bundle = Bundle(for: BundleUISmokeTester.self)
    /// STATE keys the caller knows the script declares. The smoke
    /// tester doesn't parse scripts itself — the validator does that
    /// already and the MCP layer can hand them in. Empty array skips
    /// the state probe entirely.
    fileprivate var declaredStateKeys: [String] = []

    fileprivate static let bundleScheme = "conjuredsp-preset"

    // MARK: - Lifecycle

    private func start(
        bundle: PresetBundle,
        hostParameterNames: [Int: String],
        hostParameterCount: Int,
        timeout: TimeInterval,
        completion: @escaping (Report) -> Void
    ) {
        self.completion = completion
        self.hostParameterNames = hostParameterNames
        self.hostParameterCount = hostParameterCount

        // Size the offscreen WKWebView to match the manifest's declared
        // UI dimensions. Without this the webview defaulted to 400×240,
        // which let oversized content lay out happily in the smoke test
        // even when the live plugin (which pins the webview to
        // manifest.ui.{width,height}) would clip it. The overflow check
        // below relies on this matching — it compares the rendered
        // scroll extent against the same declared dimensions.
        // Defaults mirror what CustomUIWebView falls back to when the
        // manifest omits a `ui` block.
        let w = bundle.manifest.ui?.width ?? 400
        let h = bundle.manifest.ui?.height ?? 240
        self.declaredWidth = w
        self.declaredHeight = h

        let config = WKWebViewConfiguration()
        // ─── Isolation from the plugin's live custom-UI WKWebView ───
        //
        // BundleUISmokeTester and CustomUIWebView BOTH create WKWebViews
        // in the same extension (AU view service) process. Any state
        // shared between them — a process pool, a data store, a scheme
        // name, a parent NSWindow — has been observed to corrupt the
        // run loop's autorelease pool, crashing the extension during a
        // later main-thread event drain (mouse hover, @Published fan-
        // out, etc.). Empirically tested layers:
        //
        //   1. Private WKProcessPool isolates the WebContent process.
        //   2. Non-persistent WKWebsiteDataStore isolates cookies +
        //      IndexedDB + local storage bookkeeping.
        //   3. Unique URL scheme per instance avoids colliding handler
        //      registrations across two configs in the same process.
        //   4. No offscreen NSWindow — see below.
        config.processPool = WKProcessPool()
        config.websiteDataStore = .nonPersistent()
        let scheme = "\(Self.bundleScheme)-smoke-\(UUID().uuidString.prefix(8).lowercased())"
        customScheme = scheme
        let handler = BundleAssetSchemeHandler(rootURL: bundle.rootURL)
        config.setURLSchemeHandler(handler, forURLScheme: scheme)
        schemeHandler = handler

        // Inject the bridge, the component library, AND an
        // instrumentation shim that captures JS errors + wraps the
        // bridge's parameters.set so the probe can count writes.
        if let bridgeSource = bridgeSource() {
            config.userContentController.addUserScript(
                WKUserScript(source: bridgeSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        if let uiLibSource = uiLibrarySource() {
            config.userContentController.addUserScript(
                WKUserScript(source: uiLibSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
        config.userContentController.addUserScript(
            WKUserScript(source: Self.instrumentationShim, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        config.userContentController.add(self, name: "smokeReady")
        // The bridge's `safeInvoke` wraps every user callback (ready,
        // onChange, onAnyChange, audio.onFrame, etc.) in a try/catch
        // and posts any exception through `postTo('log', ...)`. Those
        // never reach window.onerror. Register a `log` handler so we
        // can surface those errors too — otherwise a throw inside
        // `ConjureDSP.ready(cb)` silently vanishes.
        config.userContentController.add(self, name: "log")
        config.userContentController.add(self, name: "consoleLog")

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: config)
        wv.navigationDelegate = self
        // No NSWindow. Adding a second NSWindow to an
        // `NSViewServiceApplication`'s window list has been observed
        // to corrupt ViewBridge's event plumbing — subsequent mouse
        // events to the plugin's own (ViewBridge-owned) window leave
        // zombie ObjC pointers in the main-thread autorelease pool,
        // which SIGSEGVs the extension on the next pool drain (often
        // seconds later). WKWebView runs its JS + fires its message
        // handlers whether or not it's in a view hierarchy, so long
        // as we hold a strong reference — which we do via `webView`.
        webView = wv

        // 3 s hard timeout. If the webview hangs (infinite loop, non-
        // terminating load), return a fail report anyway so the MCP
        // caller doesn't hang.
        let timeoutWork = DispatchWorkItem { [weak self] in
            self?.finish(reason: "timeout after \(timeout)s")
        }
        timeoutTask = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        loadStart = CFAbsoluteTimeGetCurrent()
        let entryPath = bundle.manifest.uiEntryHTMLPath
        let encoded = entryPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryPath
        guard let url = URL(string: "\(customScheme)://preset/\(encoded)") else {
            log.error("smoke test: bad entry URL for \(entryPath, privacy: .public)")
            finish(reason: "invalid entry URL")
            return
        }
        wv.load(URLRequest(url: url))
    }

    /// One-shot completion — subsequent calls are no-ops so timeout +
    /// ready + load-failure can all race without double-resuming the
    /// continuation.
    private func finish(reason: String? = nil) {
        guard !didComplete else { return }
        didComplete = true
        timeoutTask?.cancel()
        timeoutTask = nil

        // The probe script is synchronous; run it even on timeout so we
        // capture whatever errors/components exist at that moment.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await self.collectReport(timeoutReason: reason)
            self.teardown()
            self.completion?(report)
            self.completion = nil
        }
    }

    private func teardown() {
        if let wv = webView {
            wv.configuration.userContentController.removeAllUserScripts()
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "smokeReady")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "log")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "consoleLog")
            wv.navigationDelegate = nil
        }
        webView = nil
    }

    // MARK: - Report collection

    private func collectReport(timeoutReason: String?) async -> Report {
        // Ask the probe for its current state. Works even without the
        // ready signal — captures JS errors from a UI that failed to
        // initialize.
        let probeJSON: String = await withCheckedContinuation { cont in
            guard let wv = webView else { cont.resume(returning: "{}"); return }
            wv.evaluateJavaScript(Self.probeScript) { result, _ in
                cont.resume(returning: (result as? String) ?? "{}")
            }
        }

        // Measure the rendered scroll extent. Some pages park their
        // content on body, some on documentElement (depends on whether
        // the author set `html { height: 100% }` etc.) — take the max
        // of both so we report the true content size regardless. Only
        // collected when ready actually fired; before that the layout
        // hasn't settled and the numbers are misleading.
        let renderedDims: (Int, Int)? = await withCheckedContinuation { cont in
            guard let wv = webView, readyAtMs != nil else {
                cont.resume(returning: nil); return
            }
            wv.evaluateJavaScript(Self.scrollExtentScript) { result, _ in
                guard let arr = result as? [Any], arr.count >= 4,
                      let bw = (arr[0] as? NSNumber)?.intValue,
                      let bh = (arr[1] as? NSNumber)?.intValue,
                      let dw = (arr[2] as? NSNumber)?.intValue,
                      let dh = (arr[3] as? NSNumber)?.intValue
                else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: (max(bw, dw), max(bh, dh)))
            }
        }

        var jsErrors: [JSLogEntry] = []
        var componentsRaw: [ComponentReport] = []
        var lowContrastTexts: [TextContrastIssue] = []
        if let data = probeJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errs = obj["errors"] as? [[String: Any]] {
                for e in errs {
                    jsErrors.append(JSLogEntry(
                        kind: (e["kind"] as? String) ?? "error",
                        message: (e["message"] as? String) ?? "",
                        atMs: (e["atMs"] as? Double) ?? 0
                    ))
                }
            }
            if let comps = obj["components"] as? [[String: Any]] {
                for c in comps {
                    componentsRaw.append(ComponentReport(
                        tag: (c["tag"] as? String) ?? "",
                        param: c["param"] as? String,
                        paramX: c["paramX"] as? String,
                        paramY: c["paramY"] as? String,
                        bound: (c["bound"] as? Bool) ?? false,
                        reason: c["reason"] as? String
                    ))
                }
            }
            if let contrasts = obj["contrasts"] as? [[String: Any]] {
                for c in contrasts {
                    lowContrastTexts.append(TextContrastIssue(
                        selector: (c["selector"] as? String) ?? "",
                        text: (c["text"] as? String) ?? "",
                        foreground: (c["foreground"] as? String) ?? "",
                        background: (c["background"] as? String) ?? "",
                        ratio: (c["ratio"] as? Double) ?? 0
                    ))
                }
            }
        }

        // Per-param coverage: for each declared parameter in the host,
        // check whether at least one component's attribute resolves to
        // it (via the same loose matching cdp-ui uses).
        let declaredParams: [(Int, String)] = (0..<hostParameterCount).compactMap { i in
            guard let name = hostParameterNames[i] else { return nil }
            return (i, name)
        }
        let boundAttrs: Set<String> = Set(componentsRaw.compactMap { comp -> [String]? in
            guard comp.bound else { return nil }
            return [comp.param, comp.paramX, comp.paramY].compactMap { $0 }
        }.flatMap { $0 }.map(Self.looseNormalize))
        let paramCoverage = declaredParams.map { (index, name) -> ParamCoverage in
            let norm = Self.looseNormalize(name)
            let hasBinding = boundAttrs.contains(norm) || boundAttrs.contains(String(index))
            return ParamCoverage(
                index: index,
                name: name,
                hasInteractiveBinding: hasBinding,
                reason: hasBinding ? nil
                    : "No cdp-* component has a `param=\"\(name)\"` (or index) that resolves at runtime. Users can't edit this parameter via the custom UI."
            )
        }

        // Layout probe — runs only after ready fires so layout has
        // settled. Captures every interactive control's rect, flags
        // ones below per-tag minimums, and computes coverage / bbox
        // density against the manifest's declared canvas.
        var smallControls: [SmallControl] = []
        var coverageRatio: Double = 0
        var bboxRatio: Double = 0
        var layoutFlags: [String] = []
        var cellCoverage: [[Double]] = []
        var canvasIssues: [CanvasIssue] = []
        if readyAtMs != nil, let wv = webView {
            let probeJS = Self.layoutProbeScript(manifestW: declaredWidth, manifestH: declaredHeight)
            let raw: String = await withCheckedContinuation { cont in
                wv.evaluateJavaScript(probeJS) { result, _ in
                    cont.resume(returning: (result as? String) ?? "{}")
                }
            }
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let controls = obj["controls"] as? [[String: Any]] ?? []
                for c in controls {
                    let tag = (c["tag"] as? String) ?? ""
                    let w = (c["width"] as? Double) ?? 0
                    let h = (c["height"] as? Double) ?? 0
                    if Self.isControlTooSmall(tag: tag, w: w, h: h) {
                        smallControls.append(SmallControl(
                            tag: tag,
                            param: c["param"] as? String,
                            width: w,
                            height: h,
                            reason: nil,
                            detail: nil
                        ))
                    }
                }
                let squeezed = obj["squeezed"] as? [[String: Any]] ?? []
                for s in squeezed {
                    smallControls.append(SmallControl(
                        tag: (s["tag"] as? String) ?? "",
                        param: s["param"] as? String,
                        width: (s["width"] as? Double) ?? 0,
                        height: (s["height"] as? Double) ?? 0,
                        reason: s["reason"] as? String,
                        detail: s["detail"] as? String
                    ))
                }
                let canvasAreaPx = Double(declaredWidth) * Double(declaredHeight)
                if canvasAreaPx > 0 {
                    let coverage = (obj["coverage"] as? Double) ?? 0
                    let bboxW = (obj["bboxW"] as? Double) ?? 0
                    let bboxH = (obj["bboxH"] as? Double) ?? 0
                    coverageRatio = (coverage / canvasAreaPx * 1000).rounded() / 1000
                    bboxRatio = (bboxW * bboxH / canvasAreaPx * 1000).rounded() / 1000
                    // If the UI dedicates a meaningful chunk of its
                    // declared canvas to a `<canvas>` element (scope,
                    // spectrum, grain timeline, etc.), treat that area
                    // as legitimately filled rather than an empty void.
                    // The smoke tester never feeds audio, so those
                    // canvases ARE empty in this run — but that's
                    // expected, not a layout flaw.
                    let canvasFillRatio = ((obj["canvasArea"] as? Double) ?? 0) / canvasAreaPx
                    let canvasOccupied = canvasFillRatio >= 0.20
                    let hasInteractive = !controls.isEmpty
                    if hasInteractive && coverageRatio < 0.20 && !canvasOccupied {
                        layoutFlags.append("sparse")
                    }
                    if hasInteractive && bboxRatio < 0.40 && !canvasOccupied {
                        layoutFlags.append("clustered")
                    }
                }
                if let raw2D = obj["cellCoverage"] as? [[Any]] {
                    cellCoverage = raw2D.map { row in
                        row.compactMap { v -> Double? in
                            if let d = v as? Double { return d }
                            if let n = v as? NSNumber { return n.doubleValue }
                            return nil
                        }
                    }
                }
                if let extraFlags = obj["layoutFlags"] as? [String] {
                    for f in extraFlags where !layoutFlags.contains(f) {
                        layoutFlags.append(f)
                    }
                }
                if let issues = obj["canvasIssues"] as? [[String: Any]] {
                    for i in issues {
                        let layoutArr = (i["layout"] as? [Any])?.compactMap { v -> Double? in
                            if let d = v as? Double { return d }
                            if let n = v as? NSNumber { return n.doubleValue }
                            return nil
                        } ?? []
                        let bufferArr = (i["buffer"] as? [Any])?.compactMap { v -> Double? in
                            if let d = v as? Double { return d }
                            if let n = v as? NSNumber { return n.doubleValue }
                            return nil
                        } ?? []
                        canvasIssues.append(CanvasIssue(
                            id: (i["id"] as? String) ?? "",
                            layout: layoutArr,
                            buffer: bufferArr,
                            reason: (i["reason"] as? String) ?? "",
                            hint: (i["hint"] as? String) ?? ""
                        ))
                    }
                }
            }
        }

        // STATE probe — only when the caller supplied declared keys
        // and ready actually fired (probing a UI that never reached
        // ready means the bridge state surface might not exist yet).
        // Picks the first declared key, captures it, writes it back,
        // and verifies the onChange + set return.
        let stateProbe: StateProbeResult? = await runStateProbeIfPossible()

        // Build the content_overflow block when the rendered extent
        // exceeds declared on either axis by more than the tolerance.
        // Skipped entirely (nil) when ready didn't fire — the rendered
        // dims are unreliable then, and the report already flags ready
        // failure as its own status — or when content fits.
        var contentOverflow: ContentOverflow? = nil
        if let (rw, rh) = renderedDims {
            let dw = declaredWidth
            let dh = declaredHeight
            let widthOver = rw - dw > Self.overflowToleranceP
            let heightOver = rh - dh > Self.overflowToleranceP
            if widthOver || heightOver {
                var axes: [String] = []
                if widthOver { axes.append("width") }
                if heightOver { axes.append("height") }
                contentOverflow = ContentOverflow(
                    declared: ContentOverflow.Size(width: dw, height: dh),
                    rendered: ContentOverflow.Size(width: rw, height: rh),
                    overflows: axes,
                    byPixels: ContentOverflow.ByPixels(
                        width: widthOver ? rw - dw : nil,
                        height: heightOver ? rh - dh : nil
                    )
                )
            }
        }

        let readyFired = readyAtMs != nil
        var combinedErrors = jsErrors
        // bridge log channel — every entry is a `safeInvoke` catch
        // (ready(cb), onChange cb, onAnyChange cb, audio.onFrame cb,
        // etc.) that would otherwise vanish because the bridge
        // swallows the exception to keep subsequent handlers alive.
        for (text, t) in bridgeLogs {
            combinedErrors.append(
                JSLogEntry(kind: "callback_exception", message: text, atMs: t)
            )
        }
        if let reason = timeoutReason {
            combinedErrors.insert(
                JSLogEntry(kind: "harness", message: reason, atMs: 0),
                at: 0
            )
        }
        if let le = loadError {
            combinedErrors.insert(
                JSLogEntry(kind: "load", message: le, atMs: 0),
                at: 0
            )
        }

        // Aggregate status. Low contrast is a soft issue (warn) — many
        // authors deliberately ship muted/secondary text that scrapes
        // the threshold, and we'd rather not block a save on a
        // judgment call. JS errors and unbound components stay fail.
        let failureKinds: Set<String> = [
            "error", "unhandledrejection", "load", "harness", "callback_exception"
        ]
        let status: ReportStatus
        if !readyFired
            || combinedErrors.contains(where: { failureKinds.contains($0.kind) })
            || componentsRaw.contains(where: { !$0.bound })
        {
            status = .fail
        } else if paramCoverage.contains(where: { !$0.hasInteractiveBinding })
                  || !lowContrastTexts.isEmpty
        {
            status = .warn
        } else {
            status = .pass
        }

        // Roll the soft layout numbers + flags into a separate
        // advisory block. Empty advisory is omitted entirely so a
        // `status: pass` response doesn't carry items shaped like
        // problems. The advisory is populated whenever we have any
        // soft signal worth surfacing — non-zero coverage / bbox
        // ratios, a cell-coverage grid, or any advisory flag.
        let layoutAdvisory: LayoutAdvisory?
        let hasAdvisorySignal = coverageRatio > 0
            || bboxRatio > 0
            || !cellCoverage.isEmpty
            || !layoutFlags.isEmpty
        if hasAdvisorySignal {
            layoutAdvisory = LayoutAdvisory(
                coverageRatio: coverageRatio,
                bboxRatio: bboxRatio,
                cellCoverage: cellCoverage,
                flags: layoutFlags
            )
        } else {
            layoutAdvisory = nil
        }

        return Report(
            status: status,
            readyFired: readyFired,
            readyTimeMs: readyAtMs,
            loadError: loadError,
            jsErrors: combinedErrors,
            consoleLogs: consoleLogs,
            components: componentsRaw,
            params: paramCoverage,
            contentOverflow: contentOverflow,
            lowContrastTexts: lowContrastTexts,
            stateProbe: stateProbe,
            smallControls: smallControls,
            layoutAdvisory: layoutAdvisory,
            canvasIssues: canvasIssues
        )
    }

    /// Drive the JS bridge's `ConjureDSP.state.*` surface using the
    /// first declared key. Returns nil when the caller didn't supply
    /// any keys; otherwise returns a `StateProbeResult` reflecting
    /// what the JS surface answered. Errors during the probe (e.g.
    /// `state` API not present, throw inside set) collapse to the
    /// `error` field rather than failing the whole smoke test — the
    /// surface that's broken is still useful diagnostic info.
    private func runStateProbeIfPossible() async -> StateProbeResult? {
        guard let first = declaredStateKeys.first else { return nil }
        guard readyAtMs != nil else {
            return StateProbeResult(
                ran: false,
                key: first,
                getReturned: nil,
                setReturned: nil,
                onChangeFiredCount: 0,
                error: "ready did not fire — skipped state probe"
            )
        }
        guard let wv = webView else { return nil }

        // Embed the literal key into the JS — JSON-stringify it so that
        // any quote / backslash characters in the (admittedly unusual)
        // key are escaped properly. The probe runs synchronously: the
        // bridge dispatches `onChange` from inside `state.set` (same
        // contract as `parameters.set`), so we don't need a microtask
        // settle. Sync also dodges WKWebView's quirk of not unwrapping
        // returned Promises in the closure-style evaluateJavaScript.
        let keyJSON = (try? String(data: JSONSerialization.data(
            withJSONObject: first, options: [.fragmentsAllowed]
        ), encoding: .utf8)) ?? "\"\(first)\""
        let probe = """
        (function () {
            try {
                var CDP = window.ConjureDSP;
                if (!CDP || !CDP.state) {
                    return JSON.stringify({error: 'ConjureDSP.state surface missing'});
                }
                var fired = 0;
                var initial;
                try { initial = CDP.state.get(\(keyJSON)); } catch (e) {}
                try { CDP.state.onChange(\(keyJSON), function () { fired++; }); } catch (e) {}
                var ok;
                try { ok = CDP.state.set(\(keyJSON), initial); } catch (e) {
                    return JSON.stringify({error: 'state.set threw: ' + (e && e.message ? e.message : String(e))});
                }
                var returnedJSON;
                try { returnedJSON = JSON.stringify(initial); } catch (_) { returnedJSON = String(initial); }
                return JSON.stringify({
                    ok: ok === true,
                    fired: fired,
                    initial: returnedJSON
                });
            } catch (e) {
                return JSON.stringify({error: 'probe threw: ' + (e && e.message ? e.message : String(e))});
            }
        })()
        """
        let raw: String = await withCheckedContinuation { cont in
            wv.evaluateJavaScript(probe) { result, _ in
                cont.resume(returning: (result as? String) ?? "{}")
            }
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return StateProbeResult(
                ran: true,
                key: first,
                getReturned: nil,
                setReturned: nil,
                onChangeFiredCount: 0,
                error: "probe returned unparseable JSON"
            )
        }
        if let err = obj["error"] as? String {
            return StateProbeResult(
                ran: true,
                key: first,
                getReturned: nil,
                setReturned: nil,
                onChangeFiredCount: 0,
                error: err
            )
        }
        return StateProbeResult(
            ran: true,
            key: first,
            getReturned: obj["initial"] as? String,
            setReturned: obj["ok"] as? Bool,
            onChangeFiredCount: (obj["fired"] as? Int) ?? 0,
            error: nil
        )
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "smokeReady":
            readyAtMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0
            // Give the UI a beat to finish any deferred bind() calls
            // (cdp-ui's whenReady -> _bind hop), then collect the probe.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.finish()
            }
        case "log":
            let text = (message.body as? String) ?? String(describing: message.body)
            let t = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0
            bridgeLogs.append((text, t))
        case "consoleLog":
            let text = (message.body as? String) ?? String(describing: message.body)
            consoleLogs.append(text)
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The bridge's `ready(cb)` contract is gated on Swift calling
        // `_init(...)` first — in the real CustomUIWebView, that happens
        // when the webview posts the "ready" message back. We don't have
        // that handshake here (our shim listens for `ConjureDSP.ready`
        // directly), so we forward an `_init` payload after navigation
        // completes so the bridge's metadata is populated and every
        // `whenReady` callback in cdp-ui.js fires. Without this every
        // cdp-* component's _bind returns early (resolveParamAttr finds
        // no metadata) and reports as unbound.
        sendInitPayload()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadError = error.localizedDescription
        finish(reason: "webview didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadError = error.localizedDescription
        finish(reason: "webview didFailProvisional: \(error.localizedDescription)")
    }

    private func sendInitPayload() {
        guard let wv = webView else { return }
        // Build a minimal metadata array from the names the caller gave
        // us. We don't have min/max/unit here — the bridge only needs
        // `name` for loose matching to succeed, and defaults cover the
        // rest. Components that dereference meta.min / meta.max / meta.unit
        // get reasonable placeholders.
        let declared: [(Int, String)] = (0..<hostParameterCount).compactMap { i in
            guard let name = hostParameterNames[i] else { return nil }
            return (i, name)
        }
        let metadata: [[String: Any]] = declared.map { (_, name) in
            [
                "name": name,
                "min": 0.0,
                "max": 1.0,
                "default": 0.0,
                "unit": "",
                "curve": "linear",
                "style": "slider",
            ]
        }
        let values: [Double] = Array(repeating: 0.0, count: declared.count)
        let payload: [String: Any] = [
            "metadata": metadata,
            "values": values,
            "theme": "light",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.ConjureDSP && window.ConjureDSP._init(\(json));") { _, _ in }
    }

    // MARK: - Source helpers (mirror CustomUIWebView)

    private func bridgeSource() -> String? {
        guard let url = resourceBundle.url(
            forResource: "customui-bridge", withExtension: "js"
        ) else {
            log.error("smoke test: customui-bridge.js not found in extension Resources")
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func uiLibrarySource() -> String? {
        guard let url = resourceBundle.url(
            forResource: "cdp-ui", withExtension: "js"
        ) else {
            log.error("smoke test: cdp-ui.js not found in extension Resources")
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func looseNormalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Injected JS

    /// Installed at document-start, before any user script runs. Captures
    /// error + unhandledrejection + console.error/warn into a shared
    /// `window.__cdpSmokeTest` object that the probe reads later. Also
    /// signals the Swift side when `ConjureDSP.ready` fires.
    private static let instrumentationShim = """
    (function () {
        var state = {
            errors: [],
            ready: false,
        };
        window.__cdpSmokeTest = state;

        function capture(kind, message) {
            state.errors.push({
                kind: kind,
                message: String(message == null ? '' : message),
                atMs: (performance && performance.now) ? performance.now() : 0
            });
        }

        window.addEventListener('error', function (e) {
            capture('error', (e && e.message) ? e.message : (e && e.error ? String(e.error) : 'error'));
        });
        window.addEventListener('unhandledrejection', function (e) {
            var reason = e && e.reason;
            var msg = reason && (reason.message || reason.toString) ? (reason.message || reason.toString()) : String(reason);
            capture('unhandledrejection', msg);
        });
        function stringifyArg(a) {
            if (a === null) return 'null';
            if (a === undefined) return 'undefined';
            if (typeof a === 'string') return a;
            if (typeof a !== 'object') return String(a);
            try {
                var seen = new WeakSet();
                return JSON.stringify(a, function (k, v) {
                    if (typeof v === 'object' && v !== null) {
                        if (seen.has(v)) return '[Circular]';
                        seen.add(v);
                    }
                    return v;
                });
            } catch (_) {
                try { return String(a); } catch (_e) { return '[Unstringifiable]'; }
            }
        }
        function joinArgs(args) {
            return Array.prototype.slice.call(args).map(stringifyArg).join(' ');
        }
        var origErr = console.error;
        console.error = function () {
            capture('console.error', joinArgs(arguments));
            if (origErr) { origErr.apply(console, arguments); }
        };
        var origWarn = console.warn;
        console.warn = function () {
            capture('console.warn', joinArgs(arguments));
            if (origWarn) { origWarn.apply(console, arguments); }
        };
        var origLog = console.log;
        console.log = function () {
            var msg = joinArgs(arguments);
            try {
                window.webkit.messageHandlers.consoleLog.postMessage(msg);
            } catch (_) { /* harness may have torn down */ }
            if (origLog) { origLog.apply(console, arguments); }
        };

        // Poll for the bridge's ready contract, then notify Swift.
        function waitReady() {
            var CDP = window.ConjureDSP;
            if (!CDP || !CDP.ready) { return setTimeout(waitReady, 10); }
            CDP.ready(function () {
                state.ready = true;
                try {
                    window.webkit.messageHandlers.smokeReady.postMessage({});
                } catch (_) { /* harness may have torn down */ }
            });
        }
        waitReady();
    })();
    """

    /// Measures every interactive control's rendered rect post-layout.
    /// The smoke tester defers this probe behind the 150ms post-ready
    /// settle window and triggers a forced reflow via offsetHeight read,
    /// so flex / grid layout has already settled by the time this runs.
    /// Returns a JSON string with per-control dimensions plus aggregate
    /// density metrics — the Swift side compares against per-tag
    /// minimums and the manifest's declared canvas to decide which are
    /// too small or laid out too sparsely.
    private static func layoutProbeScript(manifestW: Int, manifestH: Int) -> String {
        return """
    (function () {
        try {
            void document.body.offsetHeight;
            var manifestW = \(manifestW);
            var manifestH = \(manifestH);
            var sels = ['cdp-slider', 'cdp-knob', 'cdp-toggle', 'cdp-choice', 'cdp-xy', 'button', 'input'];
            var nodes = document.querySelectorAll(sels.join(','));
            var controls = [];
            var interactiveRects = [];
            var squeezed = [];
            var layoutFlags = [];
            var minLeft = Infinity, minTop = Infinity, maxRight = -Infinity, maxBottom = -Infinity;
            var coverage = 0;
            for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                var r = el.getBoundingClientRect();
                var tag = el.tagName ? el.tagName.toLowerCase() : '';
                var paramAttr = el.getAttribute ? el.getAttribute('param') : null;
                controls.push({
                    tag: tag,
                    param: paramAttr,
                    width: r.width,
                    height: r.height
                });
                if (r.width > 0 && r.height > 0) {
                    coverage += r.width * r.height;
                    if (r.left < minLeft) minLeft = r.left;
                    if (r.top < minTop) minTop = r.top;
                    if (r.right > maxRight) maxRight = r.right;
                    if (r.bottom > maxBottom) maxBottom = r.bottom;
                    interactiveRects.push({
                        left: r.left, top: r.top, right: r.right, bottom: r.bottom
                    });
                }
            }
            var sliders = document.querySelectorAll('cdp-slider');
            for (var j = 0; j < sliders.length; j++) {
                var s = sliders[j];
                if (s.getAttribute('orientation') === 'vertical') continue;
                if (s.clientWidth === 0) continue;
                var cs = getComputedStyle(s);
                var labelW = parseFloat(cs.getPropertyValue('--cdp-label-width')) || 120;
                var valueW = parseFloat(cs.getPropertyValue('--cdp-value-width')) || 76;
                var trackW = s.clientWidth - labelW - valueW - 24;
                if (trackW < 30) {
                    squeezed.push({
                        tag: 'cdp-slider',
                        param: s.getAttribute('param') || null,
                        width: s.clientWidth,
                        height: s.clientHeight,
                        reason: 'track_squeezed',
                        detail: 'track ~' + Math.round(trackW) + 'px after label ' + labelW + ' + value ' + valueW + ' + gaps'
                    });
                }
            }
            var canvasIssues = [];
            var canvasRects = [];   // visible canvases with non-zero layout, used for advisory suppression
            var canvasArea = 0;     // total canvas layout area, intersected loosely with manifest
            var canvases = document.querySelectorAll('canvas');
            for (var ci = 0; ci < canvases.length; ci++) {
                var cv = canvases[ci];
                var cvRect = cv.getBoundingClientRect();
                if (cvRect.width <= 0 || cvRect.height <= 0) continue;
                var bufW = cv.width, bufH = cv.height;
                if (bufW === 0 || bufH === 0) {
                    canvasIssues.push({
                        id: cv.id || cv.className || '<anonymous>',
                        layout: [cvRect.width, cvRect.height],
                        buffer: [bufW, bufH],
                        reason: 'zero_buffer',
                        hint: 'Canvas has CSS size but a 0\\u00d70 drawing buffer. Author probably set cv.width/height before layout settled. Try requestAnimationFrame or a ResizeObserver before the first resize() call.'
                    });
                } else if (bufW === 300 && bufH === 150 && (Math.abs(cvRect.width - 300) > 1 || Math.abs(cvRect.height - 150) > 1)) {
                    canvasIssues.push({
                        id: cv.id || cv.className || '<anonymous>',
                        layout: [cvRect.width, cvRect.height],
                        buffer: [bufW, bufH],
                        reason: 'default_buffer_unset',
                        hint: 'Canvas drawing buffer is the HTML default 300\\u00d7150 but layout is different. Drawing will be stretched. Set cv.width = rect.width * devicePixelRatio (and likewise for height).'
                    });
                }
                // Canvases with usable buffers are eligible for advisory
                // suppression — many UIs deliberately allocate a large
                // canvas (oscilloscope, spectrum, grain timeline) that
                // only paints during audio playback. The smoke tester
                // never feeds audio, so the canvas is legitimately
                // empty in this run, but the area is NOT a layout flaw.
                if (bufW > 0 && bufH > 0) {
                    canvasRects.push({
                        left: cvRect.left, top: cvRect.top,
                        right: cvRect.right, bottom: cvRect.bottom
                    });
                    canvasArea += cvRect.width * cvRect.height;
                }
            }
            var cellCoverage = [];
            // Per-cell canvas coverage runs in lockstep with the
            // interactive-control grid so we can ask "is this 'empty'
            // cell actually covered by a canvas?" before flagging
            // empty_region.
            var canvasCellCoverage = [];
            if (manifestW >= 100 && manifestH >= 100) {
                var COLS = 3, ROWS = 3;
                var cellW = manifestW / COLS;
                var cellH = manifestH / ROWS;
                var cells = new Array(ROWS * COLS).fill(0);
                var cvCells = new Array(ROWS * COLS).fill(0);
                for (var ri = 0; ri < interactiveRects.length; ri++) {
                    var rect = interactiveRects[ri];
                    for (var cy = 0; cy < ROWS; cy++) {
                        for (var cx = 0; cx < COLS; cx++) {
                            var cellL = cx * cellW, cellT = cy * cellH;
                            var cellR = cellL + cellW, cellB = cellT + cellH;
                            var ox = Math.max(0, Math.min(rect.right, cellR) - Math.max(rect.left, cellL));
                            var oy = Math.max(0, Math.min(rect.bottom, cellB) - Math.max(rect.top, cellT));
                            cells[cy * COLS + cx] += ox * oy;
                        }
                    }
                }
                for (var cri = 0; cri < canvasRects.length; cri++) {
                    var crect = canvasRects[cri];
                    for (var ccy = 0; ccy < ROWS; ccy++) {
                        for (var ccx = 0; ccx < COLS; ccx++) {
                            var ccellL = ccx * cellW, ccellT = ccy * cellH;
                            var ccellR = ccellL + cellW, ccellB = ccellT + cellH;
                            var cox = Math.max(0, Math.min(crect.right, ccellR) - Math.max(crect.left, ccellL));
                            var coy = Math.max(0, Math.min(crect.bottom, ccellB) - Math.max(crect.top, ccellT));
                            cvCells[ccy * COLS + ccx] += cox * coy;
                        }
                    }
                }
                var cellArea = cellW * cellH;
                var flat = cells.map(function (a) { return a / cellArea; });
                var cvFlat = cvCells.map(function (a) { return a / cellArea; });
                cellCoverage = [
                    flat.slice(0, 3),
                    flat.slice(3, 6),
                    flat.slice(6, 9)
                ];
                canvasCellCoverage = [
                    cvFlat.slice(0, 3),
                    cvFlat.slice(3, 6),
                    cvFlat.slice(6, 9)
                ];
                // A cell counts as "empty" only when neither interactive
                // controls NOR a canvas meaningfully cover it. ≥ 0.30
                // canvas coverage means the user is looking at a
                // visualization area and it's not a layout flaw that
                // there are no buttons there.
                var sparseCount = 0;
                for (var fi = 0; fi < flat.length; fi++) {
                    if (flat[fi] < 0.05 && cvFlat[fi] < 0.30) sparseCount++;
                }
                var denseCount = flat.filter(function (c) { return c > 0.20; }).length;
                if (sparseCount >= 3 && denseCount >= 1) {
                    layoutFlags.push('empty_region');
                }
            }
            var hasAny = controls.some(function (c) { return c.width > 0 && c.height > 0; });
            var bboxW = hasAny ? (maxRight - minLeft) : 0;
            var bboxH = hasAny ? (maxBottom - minTop) : 0;
            return JSON.stringify({
                controls: controls,
                squeezed: squeezed,
                coverage: coverage,
                canvasArea: canvasArea,
                bboxW: bboxW,
                bboxH: bboxH,
                cellCoverage: cellCoverage,
                canvasCellCoverage: canvasCellCoverage,
                layoutFlags: layoutFlags,
                canvasIssues: canvasIssues
            });
        } catch (e) {
            return JSON.stringify({error: 'layout probe threw: ' + (e && e.message ? e.message : String(e))});
        }
    })()
    """
    }

    /// Per-tag minimum sizes (width, height) used by the layout probe
    /// to flag controls too small to grab. The slider's long-axis check
    /// uses `max(w, h) >= 60` so vertical sliders aren't false-flagged.
    private static let smallControlMinima: [String: (Double, Double)] = [
        "cdp-slider": (60, 16),
        "cdp-knob": (24, 24),
        "cdp-xy": (60, 60),
        "cdp-toggle": (28, 16),
        "cdp-choice": (60, 24),
        "button": (60, 24),
        "input": (60, 24),
    ]

    private static func isControlTooSmall(tag: String, w: Double, h: Double) -> Bool {
        guard let (minW, minH) = smallControlMinima[tag] else { return false }
        if tag == "cdp-slider" {
            return max(w, h) < minW || min(w, h) < minH
        }
        return w < minW || h < minH
    }

    /// Measures the rendered content extent on both the body and the
    /// document element (some pages put their main content on body,
    /// some on documentElement). The Swift side takes the max along
    /// each axis and compares to manifest.ui.{width,height}. Returns a
    /// 4-element number array — `evaluateJavaScript`'s portable subset
    /// of return types.
    private static let scrollExtentScript = """
    [document.body ? document.body.scrollWidth : 0,
     document.body ? document.body.scrollHeight : 0,
     document.documentElement ? document.documentElement.scrollWidth : 0,
     document.documentElement ? document.documentElement.scrollHeight : 0]
    """

    /// Run after ready fires (or on timeout). Enumerates cdp-* custom
    /// elements, reports each one's binding state, collects any captured
    /// JS errors, and computes WCAG contrast for every text-bearing
    /// element (descending into open shadow roots so slotted labels
    /// inside cdp-ui components are checked too). Serialized to a JSON
    /// string because WKWebView's `evaluateJavaScript` can only return
    /// primitive/JSON-compatible values — strings are the most portable.
    private static let probeScript = """
    (function () {
        var state = window.__cdpSmokeTest || { errors: [], ready: false };
        var report = {
            errors: state.errors || [],
            components: [],
            contrasts: [],
        };
        var tags = ['cdp-slider', 'cdp-toggle', 'cdp-choice', 'cdp-xy', 'cdp-knob', 'cdp-panel'];
        tags.forEach(function (tag) {
            var nodes = document.querySelectorAll(tag);
            for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                var param = el.getAttribute('param');
                var paramX = el.getAttribute('param-x');
                var paramY = el.getAttribute('param-y');
                var bound = true;
                var reason = null;
                if (tag === 'cdp-panel') {
                    // cdp-panel auto-renders every param; no single-
                    // param binding to verify. Treat as always bound.
                } else if (tag === 'cdp-xy') {
                    // cdp-xy stores its bindings as _cx + _cy. Both
                    // must be present for drags to actually move a
                    // parameter.
                    if (!el._cx || !el._cy) {
                        bound = false;
                        reason = 'cdp-xy never bound — param-x and/or param-y unresolved';
                    }
                } else {
                    // cdp-slider / cdp-toggle / cdp-choice / cdp-knob
                    // all store their resolved handle as _ctrl. Absence
                    // means resolveParamAttr returned -1 (typoed name,
                    // no manifest.params to search) and the component
                    // is left with a disabled input and an 'unknown'
                    // label.
                    if (!el._ctrl) {
                        bound = false;
                        reason = 'param=\"' + (param || '') + '\" did not resolve to any registered parameter';
                    }
                }
                report.components.push({
                    tag: tag, param: param, paramX: paramX, paramY: paramY,
                    bound: bound, reason: reason
                });
            }
        });

        // ─── Text contrast pass ──────────────────────────────────────
        function parseRGB(s) {
            if (!s) return null;
            var m = s.match(/^rgba?\\(([^)]+)\\)$/);
            if (!m) return null;
            var parts = m[1].split(/[,\\s\\/]+/).filter(function (p) { return p.length > 0; }).map(parseFloat);
            if (parts.length < 3) return null;
            var alpha = parts.length >= 4 ? parts[3] : 1;
            return [parts[0], parts[1], parts[2], alpha];
        }
        function srgbLin(v) {
            v = v / 255;
            return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        }
        function lumOf(rgb) {
            return 0.2126 * srgbLin(rgb[0]) + 0.7152 * srgbLin(rgb[1]) + 0.0722 * srgbLin(rgb[2]);
        }
        function contrastRatio(a, b) {
            var la = lumOf(a), lb = lumOf(b);
            var hi = Math.max(la, lb), lo = Math.min(la, lb);
            return (hi + 0.05) / (lo + 0.05);
        }
        // Walk up the flattened tree (parent element OR shadow host)
        // looking for the first non-transparent backgroundColor. Returns
        // the computed string if found, falls back to white (matches
        // WebKit's default canvas paint).
        function effectiveBg(el) {
            var node = el;
            for (var hops = 0; node && hops < 30; hops++) {
                if (node.nodeType === 1) {
                    var bg = getComputedStyle(node).backgroundColor;
                    var rgba = parseRGB(bg);
                    if (rgba && rgba[3] > 0.05) return bg;
                }
                if (node.parentElement) { node = node.parentElement; }
                else if (node.parentNode && node.parentNode.host) { node = node.parentNode.host; }
                else { node = node.parentNode; }
            }
            return 'rgb(255, 255, 255)';
        }
        function shortSelector(el) {
            var tag = el.tagName ? el.tagName.toLowerCase() : '?';
            var idPart = el.id ? '#' + el.id : '';
            var clsRaw = (typeof el.className === 'string') ? el.className : '';
            var clsPart = clsRaw ? '.' + clsRaw.trim().split(/\\s+/).slice(0, 2).join('.') : '';
            return tag + idPart + clsPart;
        }
        function ownText(el) {
            var s = '';
            for (var i = 0; i < el.childNodes.length; i++) {
                var c = el.childNodes[i];
                if (c.nodeType === 3 && c.nodeValue) s += c.nodeValue;
            }
            return s.trim();
        }
        function collect(root, out) {
            if (!root || !root.querySelectorAll) return;
            var all = root.querySelectorAll('*');
            for (var i = 0; i < all.length; i++) {
                var el = all[i];
                // Skip elements that aren't visible — display:none /
                // visibility:hidden / zero-area / aria-hidden text isn't
                // user-facing, so its contrast doesn't matter.
                var cs = getComputedStyle(el);
                if (cs.display === 'none' || cs.visibility === 'hidden') {
                    // Don't descend — children are also invisible.
                    continue;
                }
                if (ownText(el).length > 0) out.push(el);
                if (el.shadowRoot) collect(el.shadowRoot, out);
            }
        }
        try {
            var els = [];
            collect(document, els);
            var seen = {};
            for (var i = 0; i < els.length && report.contrasts.length < 10; i++) {
                var el = els[i];
                var fg = getComputedStyle(el).color;
                var bg = effectiveBg(el);
                var fgRGB = parseRGB(fg);
                var bgRGB = parseRGB(bg);
                if (!fgRGB || !bgRGB) continue;
                var r = contrastRatio(fgRGB, bgRGB);
                if (r >= 3.0) continue;
                var sel = shortSelector(el);
                // Dedupe by selector — many siblings share one rule and
                // would otherwise burn the issue cap on duplicates.
                if (seen[sel]) continue;
                seen[sel] = true;
                report.contrasts.push({
                    selector: sel,
                    text: ownText(el).slice(0, 50),
                    foreground: fg,
                    background: bg,
                    ratio: Math.round(r * 100) / 100
                });
            }
        } catch (e) {
            report.errors.push({
                kind: 'error',
                message: 'contrast probe threw: ' + (e && e.message ? e.message : String(e)),
                atMs: (performance && performance.now) ? performance.now() : 0
            });
        }
        return JSON.stringify(report);
    })();
    """
}
