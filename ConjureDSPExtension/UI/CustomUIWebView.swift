import Combine
import os
import SwiftUI
import WebKit

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension", category: "CustomUI")

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

        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "paramSet")
        contentController.add(context.coordinator, name: "ready")
        contentController.add(context.coordinator, name: "log")

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

        let entryPath = bundle.manifest.uiEntryHTMLPath
        if let url = URL(string: "\(Self.bundleScheme)://preset/\(entryPath)") {
            log.info("Loading custom UI from \(Self.bundleScheme)://preset/\(entryPath, privacy: .public)")
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
        coordinator.fileWatcher?.stop()
        coordinator.fileWatcher = nil
        coordinator.pendingReload?.cancel()
        coordinator.pendingReload = nil
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

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var parameterState: ParameterState?

        /// Retained so the scheme handler isn't torn down before WKWebView is.
        var schemeHandler: BundleAssetSchemeHandler?

        /// Watches the bundle's `ui/` directory for edits and triggers a
        /// debounced reload of the webview.
        var fileWatcher: BundleFileWatcher?

        /// Debounce cell for the hot-reload trigger. FSEventStream already
        /// coalesces bursts with its latency parameter, but the pending
        /// work item lets us coalesce further (e.g. a write + a rename
        /// right after) and collapse them into a single webView.reload().
        var pendingReload: DispatchWorkItem?

        var isReady = false
        var lastTheme: String
        var cancellables = Set<AnyCancellable>()

        /// Last values sent to JS, keyed by index. Used to suppress redundant
        /// `_paramUpdate` calls when the Combine publisher fires with an
        /// unchanged value (common right after JS sets a param — the AU
        /// observer token will echo it back).
        private var lastSentValues: [Float] = []

        /// Values the coordinator wrote to the AU from JS, plus timestamp.
        /// We skip the next observer-echo for each index to avoid feedback
        /// loops / slider jitter.
        private var suppressNextEchoForIndex: Set<Int> = []

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

        // MARK: Combine subscription to parameter values

        func subscribe(to state: ParameterState) {
            guard cancellables.isEmpty else { return }

            // Push DAW-originated value changes to JS. Diffed against
            // lastSentValues to coalesce bursts.
            state.$values
                .receive(on: DispatchQueue.main)
                .sink { [weak self] values in
                    self?.forwardValues(values)
                }
                .store(in: &cancellables)

            // Metadata (script load) — re-init the JS side with a fresh
            // payload so authored UIs see the new parameter shape.
            state.$paramMetadata
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.reinitIfReady()
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
                    let js = "window.ConjureDSP && window.ConjureDSP._paramUpdate(\(i), \(jsNumber(v)))"
                    webView.evaluateJavaScript(js) { _, _ in }
                }
            }
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
            var metadata: [[String: Any]] = []
            let count = state.values.count
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
                log.info("Custom UI bridge ready")
                isReady = true
                sendInit()

            case "paramSet":
                guard let body = message.body as? [String: Any],
                      let index = body["index"] as? Int,
                      let value = (body["value"] as? Double).map(Float.init) ?? (body["value"] as? Float),
                      let state = parameterState else { return }
                suppressNextEchoForIndex.insert(index)
                // Route through the existing binding so the AUParameter setter
                // fires (same path DAW automation uses).
                state.binding(for: index).wrappedValue = value

            case "log":
                let text = (message.body as? String) ?? String(describing: message.body)
                log.info("[preset-ui] \(text, privacy: .public)")

            default:
                break
            }
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

// MARK: - Bundle asset scheme handler

/// Serves files from a preset bundle's `ui/` directory into a WKWebView's
/// WebContent process via a custom URL scheme.
///
/// WebContent is a separate process with its own sandbox that does NOT
/// inherit the appex's App Group entitlement. Loading files directly from
/// `~/Library/Group Containers/...` via `loadFileURL` triggers
/// `kTCCServiceSystemPolicyAppData` prompts ("ConjureDSP would like to
/// access data from other apps"). By routing requests through
/// `WKURLSchemeHandler` — which runs in the appex process — we read the
/// files with the appex's entitlements and stream bytes to WebContent,
/// avoiding the TCC gate entirely.
///
/// URL format: `conjuredsp-preset://preset/<relative-path-inside-bundle>`
/// e.g. `conjuredsp-preset://preset/ui/index.html`.
final class BundleAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The bundle root (e.g. `.../RepoPresets/MyBundle.cdp`). All served
    /// paths are resolved relative to and constrained to this directory.
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(Self.error(.badURL, "missing request URL"))
            return
        }

        // Strip scheme + host; resolve path relative to rootURL.
        let relativePath = requestURL.path.hasPrefix("/")
            ? String(requestURL.path.dropFirst())
            : requestURL.path
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL

        // Sandbox: candidate must stay inside rootURL.
        guard candidate.path.hasPrefix(rootURL.path) else {
            log.error("Scheme handler rejected out-of-bundle request: \(requestURL.path, privacy: .public)")
            urlSchemeTask.didFailWithError(Self.error(.unsupportedURL, "outside bundle"))
            return
        }

        guard FileManager.default.isReadableFile(atPath: candidate.path) else {
            urlSchemeTask.didFailWithError(Self.error(.fileDoesNotExist, candidate.path))
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: candidate)
        } catch {
            urlSchemeTask.didFailWithError(error)
            return
        }

        let mime = Self.mimeType(for: candidate.pathExtension.lowercased())
        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            // Tighten what custom UIs can do. Authors may override with their
            // own <meta http-equiv="Content-Security-Policy"> tag if needed.
            "Content-Security-Policy": "default-src 'self' 'unsafe-inline' data:; connect-src 'none';",
        ]
        let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: requestURL, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil) as URLResponse

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // All reads are synchronous; nothing to cancel.
    }

    // MARK: - Helpers

    private static func error(_ code: URLError.Code, _ description: String) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "js": "application/javascript; charset=utf-8",
        "mjs": "application/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "wasm": "application/wasm",
        "map": "application/json",
        "txt": "text/plain; charset=utf-8",
    ]

    private static func mimeType(for ext: String) -> String {
        mimeTypes[ext] ?? "application/octet-stream"
    }
}
