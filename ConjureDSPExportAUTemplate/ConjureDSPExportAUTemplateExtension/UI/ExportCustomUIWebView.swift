//
//  ExportCustomUIWebView.swift
//  ConjureDSPExportAUTemplateExtension
//
//  Renders the preset's custom HTML/JS UI in a WKWebView when the exported
//  bundle was built with one. The main extension has a richer version of
//  this (CustomUIWebView.swift) with hot reload + audio frame forwarding;
//  the exported AU keeps things minimal:
//    - parameter read/write bridge (DAW automation round-trips)
//    - theme tracking
//    - scheme-handler-served assets (avoids WebContent TCC prompts)
//    - no hot reload (exported UIs are immutable)
//    - no audio frame capture (not present in the template kernel)
//
//  The JS bridge (`customui-bridge.js`) is identical to the main extension's,
//  so preset UIs that subscribe to `ConjureDSP.audio.onFrame(...)` receive
//  frames here too — driven by ExportAudioCaptureManager reading the same
//  kernel ring buffers the main extension's capture pipeline uses.
//

import Combine
import os
import SwiftUI
import WebKit

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.ExportAU", category: "CustomUI")

struct ExportCustomUIWebView: NSViewRepresentable {
    @ObservedObject var parameterState: ExportParameterState
    /// Root of the copied-in preset bundle's `ui/` directory — lives at
    /// `.appex/Contents/Resources/ui` in the exported AU.
    let uiDirectoryURL: URL
    /// `ui/index.html` (or whatever the manifest named). Relative to
    /// `uiDirectoryURL`; served as `conjuredsp-preset://preset/ui/<path>`.
    let entryHTMLPath: String
    var theme: ColorScheme
    /// Audio capture pipeline — source of per-tick RMS/peak (and optional
    /// FFT) frames forwarded to `window.ConjureDSP.audio.onFrame(...)`.
    /// Lifetime is tied to the AU; the view controller owns the instance
    /// and passes it down so multiple webview re-creations share capture
    /// state.
    var captureManager: ExportAudioCaptureManager

    fileprivate static let bundleScheme = "conjuredsp-preset"

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Scheme handler rootURL is the `.appex/Contents/Resources` directory,
        // so a URL like `conjuredsp-preset://preset/ui/index.html` resolves
        // to `<resources>/ui/index.html` on disk. Paths outside that root
        // are rejected by the handler's sandbox check.
        let resourcesRoot = uiDirectoryURL.deletingLastPathComponent()
        let schemeHandler = BundleAssetSchemeHandler(rootURL: resourcesRoot)
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
            log.error("customui-bridge.js missing from exported AU resources")
        }

        // cdp-ui.js component library (mirrors main extension).
        if let uiLibSource = Self.uiLibrarySource() {
            let userScript = WKUserScript(
                source: uiLibSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(userScript)
        } else {
            log.error("cdp-ui.js missing from exported AU resources")
        }

        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "paramSet")
        contentController.add(context.coordinator, name: "ready")
        contentController.add(context.coordinator, name: "log")
        // Accept but ignore audio-frame subscribe/unsubscribe so preset UIs
        // that call `ConjureDSP.audio.onFrame(...)` don't see postMessage
        // errors — they just never receive frames.
        contentController.add(context.coordinator, name: "subscribeAudioFrames")
        contentController.add(context.coordinator, name: "unsubscribeAudioFrames")

        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Network egress restriction comes from BundleAssetSchemeHandler's
        // CSP response header (`connect-src 'none'`). A previous
        // WKContentRuleList layer blocked custom-scheme loads in exported
        // AUs, rendering them blank. Removed — CSP covers the primary
        // threat (author JS exfiltrating via fetch/XHR/WebSocket).

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
        context.coordinator.subscribe(to: parameterState)
        context.coordinator.observeWindowVisibility()

        let entry = entryHTMLPath.hasPrefix("ui/") ? entryHTMLPath : "ui/\(entryHTMLPath)"
        if let url = URL(string: "\(Self.bundleScheme)://preset/\(entry)") {
            webView.load(URLRequest(url: url))
        } else {
            log.error("Could not form custom UI URL for entry \(entry, privacy: .public)")
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parameterState = parameterState
        coordinator.subscribe(to: parameterState)

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
        // Drop the audio consumer registration so the capture manager's
        // display link stops when this webview goes away. Without this,
        // a DAW that re-creates the view tears down one webview and
        // spins up another while capture keeps ticking against a dead
        // JS bridge.
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

    /// Read `customui-bridge.js` from the exported AU's own Resources. Cached
    /// so every new webview doesn't re-read from disk.
    private static let _cachedBridgeSource: String? = {
        let bundle = Bundle(for: Coordinator.self)
        guard let url = bundle.url(forResource: "customui-bridge", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private static func bridgeSource() -> String? { _cachedBridgeSource }

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
        weak var parameterState: ExportParameterState?
        weak var captureManager: ExportAudioCaptureManager?

        /// Retained so the scheme handler isn't torn down before WKWebView is.
        var schemeHandler: BundleAssetSchemeHandler?

        /// Stable id for registering against the capture manager's consumer
        /// set. Per-coordinator so multiple webview instances don't stomp
        /// on each other's registration.
        lazy var audioConsumerID: String = "exportCustomUI-\(ObjectIdentifier(self).hashValue)"

        /// Subscription to the capture manager's frame publisher. Non-nil
        /// only while the JS bridge has at least one onFrame subscriber.
        var audioFrameCancellable: AnyCancellable?

        /// Last-known visibility of the webview's NSWindow. When hidden
        /// we drop the consumer (capture stops) so the exported AU
        /// doesn't burn CPU computing meters the user can't see.
        private var isWindowVisible: Bool = true

        /// Frame-rate gate — at most one forward every 1/audioFPS seconds.
        /// Matches the main extension's default cadence so authored UIs
        /// see the same visual rate in-plugin and exported.
        private var audioFPS: Int = 30
        private var lastForwardTime: CFTimeInterval = 0

        /// Bound the outstanding main-thread work — if the previous
        /// evaluateJavaScript hasn't returned yet, drop the next frame.
        private var framesInFlight: Int = 0

        var isReady = false
        var lastTheme: String
        var cancellables = Set<AnyCancellable>()
        /// Separate bag for per-`ExportParameterState` subscriptions so
        /// `subscribe(to:)` can be safely re-called (e.g. from
        /// `updateNSView`) without stacking duplicates or entangling with
        /// the long-lived window-visibility observers in `cancellables`.
        /// Mirrors the main-extension fix for the same bug.
        private var paramCancellables = Set<AnyCancellable>()

        private var lastSentValues: [Float] = []
        // Echo suppression lives in the JS bridge (_lastSetAt). Swift
        // unconditionally forwards value changes; the bridge decides
        // whether to fire onChange based on proximity to the user's
        // own recent set() call. Keeps the Swift side simple and matches
        // the main extension's CustomUIWebView.

        init(theme: String) { self.lastTheme = theme }

        // MARK: Window visibility

        /// Subscribe to `NSWindow.didChangeOcclusionStateNotification` on
        /// the webview's window and pause audio capture when the plugin
        /// pane is covered/collapsed. Mirrors the main extension's
        /// CustomUIWebView.observeWindowAndReload(), minus the reload
        /// notification (exported UIs are immutable).
        func observeWindowVisibility() {
            NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
                .compactMap { $0.object as? NSWindow }
                .sink { [weak self] window in
                    guard let self, self.webView?.window === window else { return }
                    self.handleWindowOcclusionChange(visible: window.occlusionState.contains(.visible))
                }
                .store(in: &cancellables)
        }

        fileprivate func handleWindowOcclusionChange(visible: Bool) {
            guard isWindowVisible != visible else { return }
            isWindowVisible = visible
            syncCaptureConsumer()
        }

        // MARK: Audio frame forwarding

        private var shouldCaptureAudio: Bool {
            audioFrameCancellable != nil && isWindowVisible
        }

        private func syncCaptureConsumer() {
            captureManager?.setConsumer(id: audioConsumerID, active: shouldCaptureAudio)
        }

        fileprivate func startAudioFrameForwarding(wantsFFT: Bool) {
            captureManager?.includeFFT = wantsFFT
            if audioFrameCancellable == nil, let manager = captureManager {
                audioFrameCancellable = manager.audioFramePublisher
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] frame in
                        self?.forwardAudioFrame(frame, includeFFT: wantsFFT)
                    }
            }
            lastForwardTime = 0
            syncCaptureConsumer()
        }

        fileprivate func stopAudioFrameForwarding() {
            audioFrameCancellable?.cancel()
            audioFrameCancellable = nil
            captureManager?.includeFFT = false
            syncCaptureConsumer()
        }

        private func forwardAudioFrame(_ frame: AudioFrame, includeFFT: Bool) {
            guard isReady, let webView, isWindowVisible else { return }
            // fps gate against the tick timestamp — honor target rate even
            // on ProMotion displays where the display link can fire 120Hz+.
            let minInterval = 1.0 / Double(max(audioFPS, 1))
            if lastForwardTime > 0,
               frame.timestamp - lastForwardTime < minInterval - 0.001 {
                return
            }
            lastForwardTime = frame.timestamp

            if framesInFlight > 1 { return }

            var payload: [String: Any] = [
                "rmsIn": frame.rmsIn,
                "rmsOut": frame.rmsOut,
                "peakIn": frame.peakIn,
                "peakOut": frame.peakOut,
                "t": frame.timestamp,
            ]
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

        // MARK: Combine subscription

        func subscribe(to state: ExportParameterState) {
            // Clear any prior per-state subs so re-calls (e.g. from
            // `updateNSView` on identity change) rebind cleanly instead
            // of stacking duplicates. The bare `cancellables.isEmpty`
            // guard that lived here would always fail on re-call because
            // `observeWindowVisibility()` populates `cancellables` at
            // coordinator setup — making automation silently stop
            // propagating after the first view update.
            paramCancellables.removeAll()
            // Forward only EXTERNAL value changes — UI writes are
            // excluded at the Swift side via AU's originator contract.
            // See ExportParameterState.externalValueChange docs.
            state.externalValueChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] change in
                    self?.forwardExternalValue(index: change.index, value: change.value)
                }
                .store(in: &paramCancellables)
        }

        private func forwardExternalValue(index: Int, value: Float) {
            guard isReady, let webView else { return }
            if index < lastSentValues.count {
                lastSentValues[index] = value
            }
            let js = "window.ConjureDSP && window.ConjureDSP._paramUpdate(\(index), \(Self.jsNumber(value)))"
            webView.evaluateJavaScript(js) { _, _ in }
        }

        // MARK: Initial state payload

        func sendInit() {
            guard let webView, let state = parameterState else { return }
            let payload = makeInitPayload(state: state)
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = "window.ConjureDSP && window.ConjureDSP._init(\(json))"
            webView.evaluateJavaScript(js) { _, _ in }
            if let values = payload["values"] as? [Float] {
                lastSentValues = values
            }
        }

        private func makeInitPayload(state: ExportParameterState) -> [String: Any] {
            var metadata: [[String: Any]] = []
            let count = state.values.count
            for i in 0..<count {
                if let md = state.paramMetadata, i < md.count {
                    metadata.append(md[i].asDictionary())
                } else {
                    metadata.append([
                        "name": "Param \(i + 1)",
                        "min": 0.0,
                        "max": 1.0,
                        "default": 0.0,
                        "unit": "",
                        "curve": "linear",
                        "style": "slider",
                    ])
                }
            }
            return [
                "metadata": metadata,
                "values": state.values,
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
                isReady = true
                sendInit()

            case "paramSet":
                guard let body = message.body as? [String: Any],
                      let index = body["index"] as? Int,
                      let value = (body["value"] as? Double).map(Float.init) ?? (body["value"] as? Float),
                      let state = parameterState else { return }
                state.binding(for: index).wrappedValue = value

            case "log":
                let text = (message.body as? String) ?? String(describing: message.body)
                log.info("[preset-ui] \(text, privacy: .public)")

            case "subscribeAudioFrames":
                // JS passes `{ fft: true }` to opt into FFT bins; absence
                // means RMS/peak-only frames. Idempotent — re-subscribing
                // with a different flag just updates capture state.
                var wantsFFT = false
                if let body = message.body as? [String: Any],
                   let fft = body["fft"] as? Bool {
                    wantsFFT = fft
                }
                startAudioFrameForwarding(wantsFFT: wantsFFT)

            case "unsubscribeAudioFrames":
                stopAudioFrameForwarding()

            default:
                break
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log.error("ExportCustomUIWebView navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log.error("ExportCustomUIWebView provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            log.error("ExportCustomUIWebView content process terminated")
            isReady = false
            lastSentValues = []
            webView.reload()
        }

        fileprivate static func jsNumber(_ v: Float) -> String {
            guard v.isFinite else { return "0" }
            return String(v)
        }
    }

    // MARK: - Helpers

    fileprivate static func jsString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let arr = String(data: data, encoding: .utf8),
           arr.count >= 4 {
            return String(arr.dropFirst().dropLast())
        }
        return "\"\""
    }
}

// MARK: - ExportParamMetadata → JSON

extension ExportParamMetadata {
    /// Encode as a JSON-safe dictionary for the JS bridge. Matches the
    /// main extension's ParamMetadata.asDictionary() shape so preset UIs
    /// can read `ConjureDSP.parameters.metadata(i)` with the same keys
    /// in both contexts.
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
