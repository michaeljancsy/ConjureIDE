//
//  TerminalView.swift
//  ConjureDSPExtension
//
//  WKWebView wrapper for xterm.js terminal that connects to this AU instance's
//  dedicated WebSocket relay (provided by ConjureDSPTerminal companion app).
//

import os
import SwiftUI
import WebKit

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension", category: "TerminalView")

struct TerminalView: NSViewRepresentable {
    var colorScheme: ColorScheme
    var appGroupContainerURL: URL?
    var instanceID: String
    var onFirstInput: (() -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "terminalBridge")
        config.userContentController = contentController

        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        webView.setValue(false, forKey: "drawsBackground")

        let bundle = Bundle(for: Coordinator.self)
        if let terminalDir = bundle.url(forResource: "terminal", withExtension: nil),
           let terminalURL = bundle.url(forResource: "index", withExtension: "html", subdirectory: "terminal") {
            log.info("Loading terminal from \(terminalURL.path, privacy: .public)")
            webView.loadFileURL(terminalURL, allowingReadAccessTo: terminalDir)
        } else {
            log.error("Terminal resources not found in bundle: \(bundle.bundlePath, privacy: .public)")
        }

        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.disconnect()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalBridge")
        coordinator.webView = nil
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.isTerminalReady else {
            coordinator.pendingTheme = colorScheme
            return
        }
        let theme = colorScheme == .dark ? "dark" : "light"
        if coordinator.lastTheme != theme {
            coordinator.lastTheme = theme
            webView.evaluateJavaScript("terminalBridge.setTheme('\(theme)')") { _, _ in }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(appGroupContainerURL: appGroupContainerURL, instanceID: instanceID, onFirstInput: onFirstInput)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var isTerminalReady = false
        var lastTheme: String?
        var pendingTheme: ColorScheme?
        let appGroupContainerURL: URL?
        let instanceID: String
        let onFirstInput: (() -> Void)?
        private var lastConnectedPort: UInt16?
        private var portPollTask: Task<Void, Never>?

        init(appGroupContainerURL: URL?, instanceID: String, onFirstInput: (() -> Void)? = nil) {
            self.appGroupContainerURL = appGroupContainerURL
            self.instanceID = instanceID
            self.onFirstInput = onFirstInput
        }

        func disconnect() {
            portPollTask?.cancel()
            portPollTask = nil
            webView?.evaluateJavaScript("terminalBridge.disconnect()") { _, _ in }
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let event = body["event"] as? String else { return }
            let data = body["data"] as? [String: Any] ?? [:]

            switch event {
            case "terminalReady":
                isTerminalReady = true
                log.info("Terminal JS ready")

                if let theme = pendingTheme {
                    let name = theme == .dark ? "dark" : "light"
                    lastTheme = name
                    webView?.evaluateJavaScript("terminalBridge.setTheme('\(name)')") { _, _ in }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.webView?.evaluateJavaScript("terminalBridge.fit()") { _, _ in }
                }

                connectToWebSocket()

            case "connected":
                portPollTask?.cancel()
                portPollTask = nil
                webView?.evaluateJavaScript("terminalBridge.focus()") { _, _ in }

            case "firstInput":
                Analytics.track(.terminalFirstInput)
                onFirstInput?()

            case "error":
                let message = data["message"] as? String ?? "unknown"
                log.error("Terminal JS error: \(message, privacy: .public)")

            case "disconnected":
                let code = data["code"] as? Int ?? 0
                log.info("Terminal disconnected (code: \(code))")
                startPortPolling()

            case "resize":
                break

            default:
                break
            }
        }

        /// Read the wsPort from this instance's JSON file and connect xterm.js.
        /// Retries up to 30 times (1s intervals) to handle the race where the
        /// AU registers before the terminal app has started the WebSocket.
        private func connectToWebSocket(attempt: Int = 0) {
            guard let url = appGroupContainerURL else {
                log.error("App Group container not available")
                showFallbackMessage(); return
            }
            let instanceFile = url
                .appendingPathComponent("mcp-instances")
                .appendingPathComponent("\(instanceID).json")
            if let info = MCPInstanceInfo.read(from: instanceFile),
               let wsPort = info.wsPort, wsPort > 0 {
                lastConnectedPort = wsPort
                log.info("Connecting to WebSocket on port \(wsPort) (instance \(self.instanceID, privacy: .public))")
                webView?.evaluateJavaScript("terminalBridge.connect(\(wsPort))") { _, _ in }
                return
            }

            // Retry — terminal app may not have processed this instance yet
            if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.connectToWebSocket(attempt: attempt + 1)
                }
            } else {
                log.warning("WebSocket port not available after 30 retries for instance \(self.instanceID, privacy: .public)")
                showFallbackMessage()
            }
        }

        /// Poll the instance JSON file after a disconnect. If the companion app
        /// restarted and assigned a new wsPort, reconnect to it instead of
        /// letting xterm.js endlessly retry the stale port.
        private func startPortPolling() {
            portPollTask?.cancel()
            portPollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, let url = self.appGroupContainerURL else { return }

                    let instanceFile = url
                        .appendingPathComponent("mcp-instances")
                        .appendingPathComponent("\(self.instanceID).json")
                    guard let info = MCPInstanceInfo.read(from: instanceFile),
                          let wsPort = info.wsPort, wsPort > 0 else { continue }

                    if wsPort != self.lastConnectedPort {
                        log.info("WebSocket port changed \(self.lastConnectedPort.map(String.init) ?? "nil") → \(wsPort) — reconnecting (instance \(self.instanceID, privacy: .public))")
                        self.lastConnectedPort = wsPort
                        self.webView?.evaluateJavaScript("terminalBridge.connect(\(wsPort))") { _, _ in }
                        return
                    }
                }
            }
        }

        private func showFallbackMessage() {
            let msg = "\\r\\n  \\x1b[33mTerminal server not ready.\\x1b[0m\\r\\n  \\x1b[90mTry reopening the plugin window.\\x1b[0m\\r\\n"
            webView?.evaluateJavaScript("terminalBridge.write('\(msg)')") { _, _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log.error("Navigation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
