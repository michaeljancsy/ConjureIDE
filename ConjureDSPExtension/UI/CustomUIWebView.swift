import Combine
import os
import SwiftUI
import WebKit

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension", category: "CustomUI")

/// Dedicated category for tracing parameter value flow end-to-end.
/// Emits at `.notice` level so lines appear in Console.app / `log stream`
/// without any persistence-config step. Noisy on purpose — these logs
/// are the diagnostic tool, not ambient telemetry. Remove/lower the
/// level once the flow is verified working.
///
/// Filter: `log stream --predicate 'subsystem == "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension" && category == "ParamFlow"'`
private let paramFlow = Logger(
    subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension",
    category: "ParamFlow"
)

extension Notification.Name {
    /// Posted by the preset toolbar's "Reload UI" button. Any live
    /// `CustomUIWebView` observes this and reloads its current page.
    static let reloadCustomUI = Notification.Name("com.MichaelJancsy.ConjureDSP.reloadCustomUI")
}

/// Renders a preset bundle's `ui/index.html` in a WKWebView and bridges it to
/// the plugin's parameter tree.
///
/// Placed where `ParameterSlidersView` would go whenever the current preset is
/// a bundle with a present `ui/index.html`. The preset's HTML/JS talks to
/// `window.ConjureDSP` (injected by `bridge.js`) to read/write parameters and
/// react to DAW automation.
struct CustomUIWebView: NSViewRepresentable {
    @ObservedObject var parameterState: ParameterState
    let bundle: PresetBundle
    var theme: ColorScheme
    /// Source of per-tick audio frames (RMS/peak/FFT). Custom UIs opt in via
    /// `window.ConjureDSP.audio.onFrame(...)`; the subscription flips a
    /// consumer on `AudioCaptureManager` so capture runs even with the
    /// spectrogram hidden.
    var captureManager: AudioCaptureManager

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Serve the bundle's ui/ assets through a custom scheme handler that
        // runs in the appex process (which owns the App Group entitlement).
        // WKWebView's WebContent process doesn't inherit that entitlement, so
        // loadFileURL() into ~/Library/Group Containers/... triggers TCC
        // SystemPolicyAppData prompts. Routing through a scheme handler keeps
        // all disk I/O inside the appex.
        let schemeHandler = BundleAssetSchemeHandler(rootURL: bundle.rootURL)
        config.setURLSchemeHandler(schemeHandler, forURLScheme: Self.bundleScheme)
        context.coordinator.schemeHandler = schemeHandler

        // Install the bridge before any preset JS runs.
        if let bridgeSource = Self.bridgeSource() {
            let userScript = WKUserScript(
                source: bridgeSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(userScript)
        } else {
            log.error("customui-bridge.js missing from extension Resources")
        }

        // cdp-ui.js: the component library (primitives + <cdp-slider>,
        // <cdp-toggle>, <cdp-choice>, <cdp-xy>, <cdp-panel>). Injected
        // AFTER the bridge so `window.ConjureDSP` is already defined;
        // `atDocumentStart` guarantees ordering across user scripts.
        if let uiLibSource = Self.uiLibrarySource() {
            let userScript = WKUserScript(
                source: uiLibSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(userScript)
        } else {
            log.error("cdp-ui.js missing from extension Resources")
        }

        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "paramSet")
        contentController.add(context.coordinator, name: "ready")
        contentController.add(context.coordinator, name: "log")
        contentController.add(context.coordinator, name: "subscribeAudioFrames")
        contentController.add(context.coordinator, name: "unsubscribeAudioFrames")

        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Network egress restriction is handled by BundleAssetSchemeHandler's
        // `Content-Security-Policy: default-src 'self' 'unsafe-inline' data:;
        // connect-src 'none';` response header — that alone blocks fetch/XHR/
        // WebSocket from author JS. A previous attempt to layer a
        // WKContentRuleList on top produced blank exported webviews because
        // custom URL schemes aren't reliable allow-targets in content rules.

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityIdentifier("customUI")

        #if DEBUG
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        context.coordinator.webView = webView
        context.coordinator.parameterState = parameterState
        context.coordinator.captureManager = captureManager
        context.coordinator.audioFPS = bundle.manifest.resolvedFPS
        context.coordinator.audioFramesAllowed = bundle.manifest.audioFramesEnabled
        context.coordinator.subscribe(to: parameterState)
        context.coordinator.observeWindowAndReload()

        // Percent-encode the path before interpolating into the URL
        // string — bundle directories with spaces or unicode (e.g.
        // a user-saved "My Preset.cdp" or "ñ.html") would otherwise fail
        // `URL(string:)` parsing and the webview would silently stay
        // blank.
        let entryPath = bundle.manifest.uiEntryHTMLPath
        let encodedPath = entryPath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? entryPath
        if let url = URL(string: "\(Self.bundleScheme)://preset/\(encodedPath)") {
            log.info("Loading custom UI from \(Self.bundleScheme)://preset/\(encodedPath, privacy: .public)")
            webView.load(URLRequest(url: url))
        } else {
            log.error("Could not form custom UI URL for entry \(entryPath, privacy: .public)")
        }

        // Hot-reload: watch the bundle's ui/ directory for edits. On change,
        // coalesce bursts (e.g. editor atomic rename -> two events) and
        // reload the webview. Parameter state survives because the bridge
        // re-sends it on the next `ready` signal.
        if let uiDir = bundle.uiDirectoryURL {
            let watcher = BundleFileWatcher(path: uiDir.path)
            watcher.onChange = { [weak webView, weak coordinator = context.coordinator] in
                guard let webView, let coordinator else { return }
                coordinator.scheduleReload(webView: webView)
            }
            watcher.start(on: .main, latency: 0.2)
            context.coordinator.fileWatcher = watcher
        }

        return webView
    }

    /// Custom URL scheme used to serve preset bundle assets into the WebContent
    /// process without tripping macOS' cross-app-data TCC gate.
    fileprivate static let bundleScheme = "conjuredsp-preset"

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parameterState = parameterState
        coordinator.subscribe(to: parameterState)

        // Theme sync (cheap; skip if unchanged)
        let themeString = theme == .dark ? "dark" : "light"
        if coordinator.lastTheme != themeString {
            coordinator.lastTheme = themeString
            if coordinator.isReady {
                webView.evaluateJavaScript("window.ConjureDSP && window.ConjureDSP._setTheme(\(Self.jsString(themeString)))") { _, _ in }
            }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "paramSet")
        controller.removeScriptMessageHandler(forName: "ready")
        controller.removeScriptMessageHandler(forName: "log")
        controller.removeScriptMessageHandler(forName: "subscribeAudioFrames")
        controller.removeScriptMessageHandler(forName: "unsubscribeAudioFrames")
        coordinator.fileWatcher?.stop()
        coordinator.fileWatcher = nil
        coordinator.pendingReload?.cancel()
        coordinator.pendingReload = nil
        coordinator.audioFrameCancellable?.cancel()
        coordinator.audioFrameCancellable = nil
        coordinator.captureManager?.setConsumer(id: coordinator.audioConsumerID, active: false)
        coordinator.cancellables.removeAll()
        coordinator.webView = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(theme: theme == .dark ? "dark" : "light")
    }

    // MARK: - Bridge source loading

    /// Read `customui-bridge.js` from the extension bundle. Cached so every
    /// new CustomUIWebView doesn't re-read from disk.
    private static let _cachedBridgeSource: String? = {
        let bundle = Bundle(for: Coordinator.self)
        guard let url = bundle.url(forResource: "customui-bridge", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private static func bridgeSource() -> String? { _cachedBridgeSource }

    /// Read `cdp-ui.js` from the extension bundle. Cached for the same
    /// reason as the bridge — every new CustomUIWebView re-uses it.
    private static let _cachedUILibrarySource: String? = {
        let bundle = Bundle(for: Coordinator.self)
        guard let url = bundle.url(forResource: "cdp-ui", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private static func uiLibrarySource() -> String? { _cachedUILibrarySource }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var parameterState: ParameterState?
        weak var captureManager: AudioCaptureManager?

        /// Retained so the scheme handler isn't torn down before WKWebView is.
        var schemeHandler: BundleAssetSchemeHandler?

        /// Watches the bundle's `ui/` directory for edits and triggers a
        /// debounced reload of the webview.
        var fileWatcher: BundleFileWatcher?

        /// Stable id for this coordinator when registering as an audio
        /// consumer on `AudioCaptureManager`. Lets us ref-count properly
        /// when multiple custom UIs subscribe in the same session.
        lazy var audioConsumerID: String = "customUI-\(ObjectIdentifier(self).hashValue)"

        /// Active only while the JS bridge has at least one `onFrame`
        /// subscriber.
        var audioFrameCancellable: AnyCancellable?

        /// Target rate (Hz) for forwarding audio frames to JS. Sourced
        /// from the bundle's `manifest.ui.fps`; defaults to 30. Frames
        /// that arrive sooner than `1/fps` after the last forwarded one
        /// are dropped before JSON encode + evaluateJavaScript.
        var audioFPS: Int = 30
        /// Mirrors `manifest.audioFramesEnabled`. When false (the default —
        /// the manifest's `ui.audioFrames` is nil or false) we drop any
        /// `subscribeAudioFrames` request from the webview on the floor.
        /// Matches the contract documented in PresetManifest.swift.
        var audioFramesAllowed: Bool = false
        private var lastForwardTime: CFTimeInterval = 0

        /// True when any subscriber asked for FFT bins in the frame payload.
        /// When false we strip `fftIn` / `fftOut` to keep JSON small.
        private var includeFFT: Bool = false

        /// Cached visibility of the webview's NSWindow. When the plugin
        /// window is occluded (another app covers it, DAW collapses the
        /// plugin panel, etc.) we unregister the audio consumer so capture
        /// itself stops — no point computing RMS nobody will see.
        private var isWindowVisible: Bool = true

        /// Debounce cell for the hot-reload trigger. FSEventStream already
        /// coalesces bursts with its latency parameter, but the pending
        /// work item lets us coalesce further (e.g. a write + a rename
        /// right after) and collapse them into a single webView.reload().
        var pendingReload: DispatchWorkItem?

        var isReady = false
        var lastTheme: String
        var cancellables = Set<AnyCancellable>()
        /// Separate bag for per-`ParameterState` subscriptions so
        /// `subscribe(to:)` can be safely re-called (e.g. from
        /// `updateNSView` when `parameterState` identity changes) without
        /// stacking duplicate sinks or entangling with the long-lived
        /// window/notification observers in `cancellables`.
        private var paramCancellables = Set<AnyCancellable>()

        /// Last values sent to JS, keyed by index. Used to suppress redundant
        /// `_paramUpdate` calls when the Combine publisher fires with an
        /// unchanged value (common right after JS sets a param — the AU
        /// observer token will echo it back).
        private var lastSentValues: [Float] = []

        // Echo suppression used to live here as `suppressNextEchoForIndex`
        // + a 30ms debounce on forwardValues. Both were workarounds for a
        // design bug: Swift was treating every $values change as
        // forward-worthy, including echoes of the user's own paramSet.
        // JS's onChange handler writes `rng.value = v`, which jerks the
        // thumb mid-drag. The correct layer to filter is the bridge: JS
        // knows whether an incoming value is an echo of its own set()
        // call (see _lastSetAt in customui-bridge.js). Swift just forwards
        // values — the bridge decides whether to fire onChange or update
        // silently. This matches how a SwiftUI slider's drag gesture
        // owns the thumb position independently of the bound value
        // during active dragging.

        init(theme: String) {
            self.lastTheme = theme
        }

        // MARK: Hot reload

        /// Debounce-and-reload the webview. Called when the file watcher
        /// detects changes under the bundle's `ui/` directory.
        func scheduleReload(webView: WKWebView) {
            pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                log.info("Custom UI hot reload")
                self.isReady = false
                self.pendingReload = nil
                webView.reload()
            }
            pendingReload = work
            // Short extra debounce on top of FSEventStream's latency, so a
            // save + touch + rename sequence collapses into one reload.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        // MARK: Window + manual reload observation

        /// Hook up two main-thread observers:
        /// 1. `NSWindow.didChangeOcclusionStateNotification` — pause audio
        ///    capture when the plugin's window isn't visible.
        /// 2. `.reloadCustomUI` — toolbar "Reload UI" button asks the
        ///    webview to reload its page, bypassing the file-watcher.
        func observeWindowAndReload() {
            NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
                .compactMap { $0.object as? NSWindow }
                .sink { [weak self] window in
                    guard let self, self.webView?.window === window else { return }
                    self.handleWindowOcclusionChange(visible: window.occlusionState.contains(.visible))
                }
                .store(in: &cancellables)

            NotificationCenter.default.publisher(for: .reloadCustomUI)
                .sink { [weak self] _ in
                    guard let self, let webView = self.webView else { return }
                    self.scheduleReload(webView: webView)
                }
                .store(in: &cancellables)
        }

        // MARK: Combine subscription to parameter values

        func subscribe(to state: ParameterState) {
            // Clear any prior per-state subs so re-calls (e.g. from
            // `updateNSView` when parameterState identity changes) rebind
            // cleanly instead of stacking duplicates.
            paramCancellables.removeAll()

            // Forward EXTERNAL value changes to JS (DAW automation,
            // MIDI, MCP writes, preset load). Explicitly NOT subscribed
            // to `$values` — that fires for UI writes too, which would
            // echo the user's own slider drags back and fight the drag.
            // `externalValueChange` is gated by AU's originator
            // exclusion on the observer, so it sees only true external
            // updates.
            state.externalValueChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] change in
                    self?.forwardExternalValue(index: change.index, value: change.value)
                }
                .store(in: &paramCancellables)

            // Metadata (script load) — re-init the JS side with a fresh
            // payload so authored UIs see the new parameter shape.
            state.$paramMetadata
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.reinitIfReady()
                }
                .store(in: &paramCancellables)
        }

        private func forwardExternalValue(index: Int, value: Float) {
            guard isReady, let webView else {
                // paramFlow.notice("[7.swift.forward.skip] idx=\(index, privacy: .public) v=\(value, privacy: .public) reason=\(self.isReady ? "no-webview" : "not-ready", privacy: .public)")
                return
            }
            // paramFlow.notice("[7.swift.forward] idx=\(index, privacy: .public) v=\(value, privacy: .public)")
            if index < lastSentValues.count {
                lastSentValues[index] = value
            }
            let js = "window.ConjureDSP && window.ConjureDSP._paramUpdate(\(index), \(jsNumber(value)))"
            webView.evaluateJavaScript(js) { _, _ in }
        }

        // MARK: Initial state payload

        /// Encodes `{metadata, values, theme}` as a single JSON string and
        /// pushes it to JS via `_init`.
        func sendInit() {
            guard let webView, let state = parameterState else { return }
            let payload = makeInitPayload(state: state)
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = "window.ConjureDSP && window.ConjureDSP._init(\(json))"
            webView.evaluateJavaScript(js) { _, _ in }
            // Seed lastSentValues with the init values so the first `$values`
            // publish (which is usually the same as init) doesn't trigger a
            // duplicate `_paramUpdate`.
            if let values = payload["values"] as? [Float] {
                lastSentValues = values
            }
        }

        private func reinitIfReady() {
            if isReady { sendInit() }
        }

        private func makeInitPayload(state: ParameterState) -> [String: Any] {
            // Expose only the parameters the preset actually declared, not
            // the full 16-slot AU parameter tree. A preset with one `Gain`
            // param would otherwise report count=16 to JS — starter UIs
            // (and many author UIs) iterate `parameters.count` and draw
            // fifteen unused "Param 2" / "Param 3" sliders. Matches export
            // behavior, which derives count from paramMetadata.
            let count: Int = {
                if let md = state.paramMetadata, !md.isEmpty {
                    return md.count
                }
                if let names = state.paramNames, !names.isEmpty {
                    return (names.keys.max() ?? -1) + 1
                }
                return state.values.count
            }()
            var metadata: [[String: Any]] = []
            for i in 0..<count {
                if let md = state.paramMetadata, i < md.count {
                    metadata.append(md[i].asDictionary())
                } else {
                    metadata.append([
                        "name": state.paramNames?[i] ?? "Param \(i + 1)",
                        "min": 0.0,
                        "max": 1.0,
                        "default": 0.0,
                        "unit": "",
                        "curve": "linear",
                        "style": "slider",
                    ])
                }
            }
            // Truncate values to match — otherwise JS sees count=1 but
            // values array has length 16, which is harmless but misleading.
            let values = Array(state.values.prefix(count))
            return [
                "metadata": metadata,
                "values": values,
                "theme": lastTheme,
            ]
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "ready":
                log.info("Custom UI bridge ready")
                isReady = true
                sendInit()

            case "paramSet":
                // Log BEFORE the guard so we see every message that
                // arrives, not just the ones that parse cleanly. If a
                // drag fires 20 JS postMessages but only 3 show up as
                // [3.swift.paramSet], the guard is silently dropping
                // the other 17 — previously impossible to see.
                let rawBodyType = String(describing: type(of: message.body))
                // paramFlow.notice("[3.swift.paramSet.arrived] body=\(String(describing: message.body), privacy: .public) type=\(rawBodyType, privacy: .public)")
                guard let body = message.body as? [String: Any] else {
                    // paramFlow.notice("[3.swift.paramSet.DROP] reason=body-not-dict type=\(rawBodyType, privacy: .public)")
                    return
                }
                guard let index = body["index"] as? Int else {
                    let indexType = body["index"].map { String(describing: type(of: $0)) } ?? "nil"
                    // paramFlow.notice("[3.swift.paramSet.DROP] reason=index-not-int got=\(String(describing: body["index"]), privacy: .public) type=\(indexType, privacy: .public)")
                    return
                }
                let value: Float
                if let d = body["value"] as? Double {
                    value = Float(d)
                } else if let f = body["value"] as? Float {
                    value = f
                } else {
                    let valueType = body["value"].map { String(describing: type(of: $0)) } ?? "nil"
                    // paramFlow.notice("[3.swift.paramSet.DROP] reason=value-not-number got=\(String(describing: body["value"]), privacy: .public) type=\(valueType, privacy: .public)")
                    return
                }
                guard let state = parameterState else {
                    // paramFlow.notice("[3.swift.paramSet.DROP] reason=no-parameterState idx=\(index, privacy: .public) v=\(value, privacy: .public)")
                    return
                }
                // paramFlow.notice("[3.swift.paramSet] idx=\(index, privacy: .public) v=\(value, privacy: .public)")
                // Route through the existing binding so the AUParameter setter
                // fires (same path DAW automation uses). UI writes use our
                // observer token as originator so the observer is excluded
                // from its own callback → no echo back to JS.
                state.binding(for: index).wrappedValue = value

            case "log":
                let text = (message.body as? String) ?? String(describing: message.body)
                // .notice so JS-originated trace logs (stages 1 + 2, and
                // author debug) show up in `log stream` without any
                // --level flag or persistence config.
                log.notice("[preset-ui] \(text, privacy: .public)")

            case "subscribeAudioFrames":
                // Manifest gate: ignore the subscription when the bundle
                // hasn't opted in via `ui.audioFrames: true`. This matches
                // the PresetManifest contract and keeps the audio capture
                // pipeline silent for presets that don't declare they
                // want frames.
                guard audioFramesAllowed else {
                    log.info("[customui] subscribeAudioFrames ignored — manifest.ui.audioFrames is not true")
                    break
                }
                // JS may (re-)post with `{ fft: true }` to request FFT bins.
                // Absence means RMS/peak only. This is idempotent — re-
                // subscribing with a different flag just updates state.
                if let body = message.body as? [String: Any],
                   let fft = body["fft"] as? Bool {
                    includeFFT = fft
                } else {
                    includeFFT = false
                }
                startAudioFrameForwarding()

            case "unsubscribeAudioFrames":
                stopAudioFrameForwarding()

            default:
                break
            }
        }

        // MARK: Audio frame forwarding

        /// Whether audio capture should be actively running right now.
        /// Combines "JS has at least one onFrame subscriber" with
        /// "our window is visible" — if either is false, the consumer
        /// is deregistered and the display-link stops.
        private var shouldCaptureAudio: Bool {
            audioFrameCancellable != nil && isWindowVisible
        }

        private func syncCaptureState() {
            captureManager?.setConsumer(id: audioConsumerID, active: shouldCaptureAudio)
        }

        private func startAudioFrameForwarding() {
            if audioFrameCancellable == nil, let captureManager {
                audioFrameCancellable = captureManager.audioFramePublisher
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] frame in
                        self?.forwardAudioFrame(frame)
                    }
            }
            lastForwardTime = 0  // allow the first frame through immediately
            syncCaptureState()
        }

        private func stopAudioFrameForwarding() {
            audioFrameCancellable?.cancel()
            audioFrameCancellable = nil
            includeFFT = false
            syncCaptureState()
        }

        /// Track in-flight evaluateJavaScript invocations so audio frames
        /// don't queue up behind a slow main thread. If a frame can't be
        /// delivered synchronously (script still running), we just drop it.
        private var framesInFlight = 0

        private func forwardAudioFrame(_ frame: AudioFrame) {
            guard isReady, let webView, isWindowVisible else { return }
            // fps gate — throttle against the audio tick's timestamp so the
            // target rate is honored even when the display link fires at
            // 120 Hz (ProMotion) or higher.
            let minInterval = 1.0 / Double(max(audioFPS, 1))
            if lastForwardTime > 0,
               frame.timestamp - lastForwardTime < minInterval - 0.001 {
                return
            }
            lastForwardTime = frame.timestamp

            // Bound the outstanding JS work — dropping frames is fine for
            // a UI animation pipeline.
            if framesInFlight > 1 { return }

            var payload: [String: Any] = [
                "rmsIn": frame.rmsIn,
                "rmsOut": frame.rmsOut,
                "peakIn": frame.peakIn,
                "peakOut": frame.peakOut,
                "t": frame.timestamp,
            ]
            // FFT bins are opt-in via `audio.onFrame(cb, { fft: true })`.
            // 2 × halfN floats (~8 KB per tick) would otherwise dominate
            // the main-thread JSON-encode cost and provide no benefit to
            // UIs that only want RMS/peak.
            if includeFFT {
                if let fft = frame.fftOutDB { payload["fftOut"] = fft }
                if let fft = frame.fftInDB { payload["fftIn"] = fft }
            }

            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let json = String(data: data, encoding: .utf8) else { return }

            framesInFlight += 1
            let js = "window.ConjureDSP && window.ConjureDSP._audioFrame(\(json))"
            webView.evaluateJavaScript(js) { [weak self] _, _ in
                self?.framesInFlight = max(0, (self?.framesInFlight ?? 1) - 1)
            }
        }

        // MARK: Window visibility

        /// Called when the webview's NSWindow changes occlusion state. Pauses
        /// audio capture and frame forwarding when the window is hidden.
        fileprivate func handleWindowOcclusionChange(visible: Bool) {
            guard isWindowVisible != visible else { return }
            isWindowVisible = visible
            syncCaptureState()
            log.info("Custom UI window visibility: \(visible, privacy: .public)")
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log.error("CustomUIWebView navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log.error("CustomUIWebView provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            log.error("CustomUIWebView content process terminated")
            isReady = false
            lastSentValues = []
            webView.reload()
        }
    }

    // MARK: - Value escaping

    /// Encode a Swift `Float` as a JS-safe numeric literal (finite guard).
    fileprivate static func jsNumber(_ v: Float) -> String {
        guard v.isFinite else { return "0" }
        return String(v)
    }

    /// Encode a Swift string as a JSON string literal. Used for small static
    /// values only — larger payloads go through JSONSerialization.
    fileprivate static func jsString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let arr = String(data: data, encoding: .utf8),
           arr.count >= 4 {
            // arr is like `["hello"]` — strip the brackets.
            return String(arr.dropFirst().dropLast())
        }
        return "\"\"" // unreachable fallback
    }
}

// Bridge Coordinator.forwardValues → `jsNumber` helper without going through the outer type.
private func jsNumber(_ v: Float) -> String {
    guard v.isFinite else { return "0" }
    return String(v)
}

// MARK: - ParamMetadata → JSON

extension ConjureDSPExtensionAudioUnit.ParamMetadata {
    /// Encode as a JSON-safe dictionary for the JS bridge. Preserves all
    /// fields the JS `parameters.metadata(i)` API promises.
    func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "min": min,
            "max": max,
            "default": self.default,
            "unit": unit,
            "curve": curve ?? "linear",
            "style": style ?? "slider",
        ]
        if let key, !key.isEmpty { dict["key"] = key }
        if let options, !options.isEmpty { dict["options"] = options }
        return dict
    }
}

// Scheme handler lives in `BundleAssetSchemeHandler.swift` — extracted so
// its pure-function `resolve(requestURL:)` is easy to unit-test without
// spinning up a WKWebView.
