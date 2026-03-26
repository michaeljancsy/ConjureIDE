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

/// Container NSView that intercepts keyboard events for the terminal WKWebView.
///
/// In AU extension ViewBridge contexts, the terminal WKWebView never becomes
/// first responder when clicked (confirmed: JS receives mousedown but not
/// keydown). Meanwhile, Monaco's WKWebView consumes all keyDown events via
/// performKeyEquivalent because it IS the first responder. Modifier-only
/// keys (Command) bypass performKeyEquivalent and reach the terminal.
///
/// This container overrides performKeyEquivalent to capture keyboard events
/// when the terminal has "logical focus" (user clicked inside the terminal),
/// converts them to terminal escape sequences, and sends them directly to
/// the WebSocket via JavaScript — bypassing the broken responder chain.
class TerminalHostView: NSView {
    weak var webView: WKWebView?

    /// True when the user last clicked inside the terminal area.
    /// Set by the Coordinator via the JS mousedown callback and the
    /// NSEvent monitor for clicks outside the terminal.
    var hasTerminalFocus: Bool = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard hasTerminalFocus, webView != nil else {
            return super.performKeyEquivalent(with: event)
        }

        // Let Cmd+key through for app shortcuts (Cmd+S, Cmd+R, Cmd+N)
        if event.modifierFlags.contains(.command) {
            return super.performKeyEquivalent(with: event)
        }

        // Capture the key for the terminal
        if let data = terminalInputData(for: event) {
            sendToTerminal(data)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    // Also handle keyDown in case performKeyEquivalent doesn't fire for some events
    override func keyDown(with event: NSEvent) {
        guard hasTerminalFocus else {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        if let data = terminalInputData(for: event) {
            sendToTerminal(data)
        } else {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Key conversion

    private func sendToTerminal(_ data: Data) {
        guard let webView = webView else { return }
        let b64 = data.base64EncodedString()
        webView.evaluateJavaScript("terminalBridge.sendInputBase64('\(b64)')") { _, error in
            if let error = error {
                log.warning("sendInputBase64 error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Convert an NSEvent to terminal input bytes.
    private func terminalInputData(for event: NSEvent) -> Data? {
        let str: String

        // Ctrl+key → control codes (Ctrl+C = 0x03, Ctrl+D = 0x04, etc.)
        if event.modifierFlags.contains(.control) {
            if let chars = event.charactersIgnoringModifiers?.lowercased(),
               let c = chars.first,
               let ascii = c.asciiValue, ascii >= 0x61, ascii <= 0x7A { // a-z
                let ctrlCode = ascii - 0x61 + 1 // a→1, b→2, ... z→26
                return Data([ctrlCode])
            }
            // Ctrl+other: pass through characters if available
            if let chars = event.characters, !chars.isEmpty {
                return chars.data(using: .utf8)
            }
            return nil
        }

        // Special keys → terminal escape sequences
        switch Int(event.keyCode) {
        case 36:  str = "\r"            // Return
        case 76:  str = "\r"            // Numpad Enter
        case 53:  str = "\u{1b}"        // Escape
        case 51:  str = "\u{7f}"        // Backspace
        case 48:  str = "\t"            // Tab
        case 123: str = "\u{1b}[D"      // Left arrow
        case 124: str = "\u{1b}[C"      // Right arrow
        case 125: str = "\u{1b}[B"      // Down arrow
        case 126: str = "\u{1b}[A"      // Up arrow
        case 115: str = "\u{1b}[H"      // Home
        case 119: str = "\u{1b}[F"      // End
        case 116: str = "\u{1b}[5~"     // Page Up
        case 121: str = "\u{1b}[6~"     // Page Down
        case 117: str = "\u{1b}[3~"     // Forward Delete
        default:
            // Regular characters
            guard let chars = event.characters, !chars.isEmpty else { return nil }
            str = chars
        }

        return str.data(using: .utf8)
    }
}

struct TerminalView: NSViewRepresentable {
    var colorScheme: ColorScheme
    var isVisible: Bool

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView()

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "terminalBridge")
        config.userContentController = contentController

        // Allow local file access for xterm.js resources
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.webView = webView
        context.coordinator.hostView = container
        container.webView = webView

        // Transparent background
        webView.setValue(false, forKey: "drawsBackground")

        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Load terminal HTML from extension bundle
        let bundle = Bundle(for: Coordinator.self)
        if let terminalDir = bundle.url(forResource: "terminal", withExtension: nil),
           let terminalURL = bundle.url(forResource: "index", withExtension: "html", subdirectory: "terminal") {
            log.info("Loading terminal from \(terminalURL.path, privacy: .public)")
            webView.loadFileURL(terminalURL, allowingReadAccessTo: terminalDir)
        } else {
            log.error("Terminal resources not found in bundle \(bundle.bundlePath, privacy: .public)")
        }

        return container
    }

    static func dismantleNSView(_ container: TerminalHostView, coordinator: Coordinator) {
        log.info("TerminalView dismantled")
        coordinator.disconnect()
        coordinator.removeEventMonitor()
        if let webView = container.webView {
            let controller = webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: "terminalBridge")
        }
        coordinator.webView = nil
        coordinator.hostView = nil
        container.webView = nil
    }

    func updateNSView(_ container: TerminalHostView, context: Context) {
        let coordinator = context.coordinator

        guard coordinator.isTerminalReady else {
            coordinator.pendingTheme = colorScheme
            coordinator.pendingVisible = isVisible
            return
        }

        // Update theme
        let theme = colorScheme == .dark ? "dark" : "light"
        if coordinator.lastTheme != theme {
            coordinator.lastTheme = theme
            container.webView?.evaluateJavaScript("terminalBridge.setTheme('\(theme)')") { _, _ in }
        }

        // Fit + focus terminal when becoming visible
        if isVisible && !coordinator.wasVisible {
            container.webView?.evaluateJavaScript("terminalBridge.fit()") { _, _ in }
            container.webView?.evaluateJavaScript("terminalBridge.focus()") { _, _ in }
        }
        coordinator.wasVisible = isVisible
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var hostView: TerminalHostView?
        var isTerminalReady = false
        var lastTheme: String?
        var pendingTheme: ColorScheme?
        var pendingVisible: Bool?
        var wasVisible = false
        private var wsPort: UInt16?
        private var eventMonitor: Any?

        deinit {
            removeEventMonitor()
        }

        func removeEventMonitor() {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }

        /// Install a local event monitor that tracks whether the terminal
        /// or some other view was last clicked. This sets hasTerminalFocus
        /// on the host view so performKeyEquivalent knows whether to
        /// capture keyboard events.
        private func installEventMonitor() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self = self,
                      let webView = self.webView,
                      let hostView = self.hostView,
                      let window = webView.window else { return event }
                let point = webView.convert(event.locationInWindow, from: nil)
                let inside = webView.bounds.contains(point)
                hostView.hasTerminalFocus = inside
                if inside {
                    log.info("Terminal gained logical focus")
                } else {
                    log.info("Terminal lost logical focus")
                }
                return event
            }
            log.info("Installed click-to-focus event monitor")
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

                // Install event monitor for focus tracking
                installEventMonitor()

                // Apply pending theme
                if let theme = pendingTheme {
                    let themeName = theme == .dark ? "dark" : "light"
                    lastTheme = themeName
                    webView?.evaluateJavaScript("terminalBridge.setTheme('\(themeName)')") { _, _ in }
                }

                // Fit terminal if it's already visible when ready
                if pendingVisible == true {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.webView?.evaluateJavaScript("terminalBridge.fit()") { _, _ in }
                    }
                    wasVisible = true
                }

                // Read WebSocket port from App Group and connect
                connectToWebSocket()

            case "connected":
                log.info("Terminal connected to WebSocket")
                webView?.evaluateJavaScript("terminalBridge.focus()") { _, _ in }

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
