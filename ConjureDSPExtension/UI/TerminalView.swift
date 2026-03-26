//
//  TerminalView.swift
//  ConjureDSPExtension
//
//  WKWebView wrapper for xterm.js terminal that connects to the host app's
//  WebSocket relay to display Claude Code.
//

import os
import SwiftUI
import WebKit

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension", category: "TerminalView")

/// Terminal view using the same NSViewRepresentable pattern as MonacoEditorView:
/// returns a bare WKWebView with no container wrappers.
struct TerminalView: NSViewRepresentable {
    var colorScheme: ColorScheme

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "terminalBridge")
        config.userContentController = contentController

        // Allow local file access for xterm.js resources
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // Transparent background
        webView.setValue(false, forKey: "drawsBackground")

        // Load terminal HTML from extension bundle
        let bundle = Bundle(for: Coordinator.self)
        if let terminalDir = bundle.url(forResource: "terminal", withExtension: nil),
           let terminalURL = bundle.url(forResource: "index", withExtension: "html", subdirectory: "terminal") {
            log.info("Loading terminal from \(terminalURL.path, privacy: .public)")
            webView.loadFileURL(terminalURL, allowingReadAccessTo: terminalDir)
        } else {
            log.error("Terminal resources not found in bundle \(bundle.bundlePath, privacy: .public)")
        }

        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        log.info("TerminalView dismantled")
        coordinator.disconnect()
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "terminalBridge")
        coordinator.webView = nil
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator

        guard coordinator.isTerminalReady else {
            coordinator.pendingTheme = colorScheme
            return
        }

        // Update theme
        let theme = colorScheme == .dark ? "dark" : "light"
        if coordinator.lastTheme != theme {
            coordinator.lastTheme = theme
            webView.evaluateJavaScript("terminalBridge.setTheme('\(theme)')") { _, _ in }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var isTerminalReady = false
        var lastTheme: String?
        var pendingTheme: ColorScheme?

        /// Log first responder and view hierarchy info for debugging keyboard issues.
        func logResponderState(context: String) {
            guard let webView = webView else {
                log.info("[\(context, privacy: .public)] webView is nil")
                return
            }
            let window = webView.window
            let firstResponder = window?.firstResponder
            let frType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let frClass = firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil"
            let windowType = window.map { String(describing: type(of: $0)) } ?? "nil"
            let isKey = window?.isKeyWindow ?? false
            let acceptsFR = webView.acceptsFirstResponder

            log.info("""
            [\(context, privacy: .public)] \
            window=\(windowType, privacy: .public) isKey=\(isKey) \
            firstResponder=\(frType, privacy: .public) (\(frClass, privacy: .public)) \
            webView.acceptsFirstResponder=\(acceptsFR) \
            webView.window!=nil: \(window != nil)
            """)

            // Walk the responder chain from the WKWebView
            var responder: NSResponder? = webView
            var chain: [String] = []
            while let r = responder, chain.count < 10 {
                chain.append(String(describing: type(of: r)))
                responder = r.nextResponder
            }
            log.info("[\(context, privacy: .public)] responder chain: \(chain.joined(separator: " → "), privacy: .public)")
        }

        func disconnect() {
            webView?.evaluateJavaScript("terminalBridge.disconnect()") { _, _ in }
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let event = body["event"] as? String else { return }

            let data = body["data"] as? [String: Any] ?? [:]

            switch event {
            case "terminalReady":
                isTerminalReady = true
                log.info("Terminal ready")

                // Apply pending theme
                if let theme = pendingTheme {
                    let themeName = theme == .dark ? "dark" : "light"
                    lastTheme = themeName
                    webView?.evaluateJavaScript("terminalBridge.setTheme('\(themeName)')") { _, _ in }
                }

                // Fit terminal
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.webView?.evaluateJavaScript("terminalBridge.fit()") { _, _ in }
                }

                // Read WebSocket port from App Group and connect
                connectToWebSocket()

            case "connected":
                log.info("Terminal connected to WebSocket")
                webView?.evaluateJavaScript("terminalBridge.focus()") { _, _ in }
                // Diagnostic: log first responder and view hierarchy info
                logResponderState(context: "after connect")

            case "disconnected":
                let code = data["code"] as? Int ?? 0
                log.info("Terminal disconnected from WebSocket (code: \(code))")

            case "resize":
                if let cols = data["cols"] as? Int, let rows = data["rows"] as? Int {
                    log.debug("Terminal resized: \(cols)x\(rows)")
                }

            case "debug":
                let msg = data["message"] as? String ?? ""
                log.info("Terminal debug: \(msg, privacy: .public)")
                // Log responder state on every click
                if msg.contains("[click]") {
                    logResponderState(context: "after click")
                    // Also try to explicitly become first responder
                    if let webView = webView, let window = webView.window {
                        let result = window.makeFirstResponder(webView)
                        log.info("makeFirstResponder(webView) returned \(result, privacy: .public)")
                        logResponderState(context: "after makeFirstResponder")
                    }
                }

            default:
                break
            }
        }

        // MARK: - WebSocket Connection

        private func connectToWebSocket() {
            guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.MichaelJancsy.ConjureDSP") else {
                log.warning("Failed to get App Group container URL")
                showFallbackMessage()
                return
            }

            let portFileURL = containerURL.appendingPathComponent("terminal-server-port")
            guard let portString = try? String(contentsOf: portFileURL, encoding: .utf8),
                  let port = UInt16(portString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                log.info("No terminal server port found — host app may not be running")
                showFallbackMessage()
                return
            }

            log.info("Connecting terminal to WebSocket on port \(port)")
            webView?.evaluateJavaScript("terminalBridge.connect(\(port))") { _, _ in }
        }

        private func showFallbackMessage() {
            let message = "\\r\\n  \\x1b[33mClaude Code terminal requires the ConjureDSP host app.\\x1b[0m\\r\\n  \\x1b[90mOpen ConjureDSP.app to enable the AI terminal.\\x1b[0m\\r\\n"
            webView?.evaluateJavaScript("terminalBridge.write('\(message)')") { _, _ in }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log.info("Terminal HTML loaded")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log.error("Terminal navigation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
