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
//  so preset UIs that subscribe to `ConjureDSP.audio.onFrame(...)` don't
//  crash — `subscribeAudioFrames` messages land in Swift and are ignored,
//  and no frames are ever posted back.
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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityIdentifier("customUI")

        #if DEBUG
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        context.coordinator.webView = webView
        context.coordinator.parameterState = parameterState
        context.coordinator.subscribe(to: parameterState)

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

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var parameterState: ExportParameterState?

        /// Retained so the scheme handler isn't torn down before WKWebView is.
        var schemeHandler: BundleAssetSchemeHandler?

        var isReady = false
        var lastTheme: String
        var cancellables = Set<AnyCancellable>()

        private var lastSentValues: [Float] = []
        private var suppressNextEchoForIndex: Set<Int> = []

        init(theme: String) { self.lastTheme = theme }

        // MARK: Combine subscription

        func subscribe(to state: ExportParameterState) {
            guard cancellables.isEmpty else { return }
            state.$values
                .receive(on: DispatchQueue.main)
                .sink { [weak self] values in
                    self?.forwardValues(values)
                }
                .store(in: &cancellables)
        }

        private func forwardValues(_ values: [Float]) {
            guard isReady, let webView else { return }
            if lastSentValues.count != values.count {
                lastSentValues = Array(repeating: .nan, count: values.count)
            }
            for i in 0..<values.count {
                let v = values[i]
                if suppressNextEchoForIndex.remove(i) != nil && v == lastSentValues[i] {
                    continue
                }
                if lastSentValues[i] != v {
                    lastSentValues[i] = v
                    let js = "window.ConjureDSP && window.ConjureDSP._paramUpdate(\(i), \(Self.jsNumber(v)))"
                    webView.evaluateJavaScript(js) { _, _ in }
                }
            }
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
                suppressNextEchoForIndex.insert(index)
                state.binding(for: index).wrappedValue = value

            case "log":
                let text = (message.body as? String) ?? String(describing: message.body)
                log.info("[preset-ui] \(text, privacy: .public)")

            case "subscribeAudioFrames", "unsubscribeAudioFrames":
                // Accepted but not wired — the exported AU template doesn't
                // carry the main extension's audio capture pipeline.
                break

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
