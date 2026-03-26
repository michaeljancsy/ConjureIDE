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
        private var wsPort: UInt16?

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

                // Read WebSocket port from App Group and connect
                connectToWebSocket()

            case "connected":
                log.info("Terminal connected to WebSocket")
                // Focus the terminal so it receives keyboard input
                webView?.evaluateJavaScript("terminalBridge.focus()") { _, _ in }
                // Make WKWebView the first responder so macOS routes keyboard events to it
                if let webView = webView {
                    webView.window?.makeFirstResponder(webView)
                }

            case "disconnected":
                let code = data["code"] as? Int ?? 0
                log.info("Terminal disconnected from WebSocket (code: \(code))")

            case "resize":
                if let cols = data["cols"] as? Int, let rows = data["rows"] as? Int {
                    log.debug("Terminal resized: \(cols)x\(rows)")
                }

            default:
                break
            }
        }

        // MARK: - WebSocket Connection

        private func connectToWebSocket() {
            // Read port from App Group container
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

            wsPort = port
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
