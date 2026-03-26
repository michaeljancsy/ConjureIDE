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
/// first responder, so regular keyDown events never reach it. However,
/// performKeyEquivalent IS called on all views in the hierarchy for every
/// keyDown event — and we confirmed that Cmd+key events DO reach the WKWebView
/// through this path (JS keydown fires for Cmd+A, Cmd+C, etc.).
///
/// This container overrides performKeyEquivalent to intercept ALL key events
/// (not just Cmd+key) when the terminal has logical focus, converts them to
/// terminal escape sequences, and sends them to the WebSocket via JavaScript.
class TerminalHostView: NSView {
    weak var webView: WKWebView?
    var hasTerminalFocus: Bool = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // DIAGNOSTIC: Log every call to see what events reach this method
        let keyChar = event.characters ?? "?"
        let keyCode = event.keyCode
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modStr = [
            mods.contains(.command) ? "Cmd" : nil,
            mods.contains(.control) ? "Ctrl" : nil,
            mods.contains(.option) ? "Opt" : nil,
            mods.contains(.shift) ? "Shift" : nil,
        ].compactMap { $0 }.joined(separator: "+")
        let diagMsg = "performKeyEquivalent: key='\(keyChar)' code=\(keyCode) mods=[\(modStr)] hasFocus=\(hasTerminalFocus)"
        let escaped = diagMsg
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("terminalBridge.write('\\r\\n\\x1b[35m\(escaped)\\x1b[0m\\r\\n')") { _, _ in }

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

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Key conversion

    private func sendToTerminal(_ data: Data) {
        guard let webView = webView else { return }
        let b64 = data.base64EncodedString()
        webView.evaluateJavaScript("terminalBridge.sendInputBase64('\(b64)')") { _, _ in }
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
            guard let chars = event.characters, !chars.isEmpty else { return nil }
            str = chars
        }

        return str.data(using: .utf8)
    }
}

struct TerminalView: NSViewRepresentable {
    var colorScheme: ColorScheme

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView()

        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "terminalBridge")
        config.userContentController = contentController

        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.webView = webView
        context.coordinator.hostView = container
        container.webView = webView

        webView.setValue(false, forKey: "drawsBackground")

        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let bundle = Bundle(for: Coordinator.self)
        if let terminalDir = bundle.url(forResource: "terminal", withExtension: nil),
           let terminalURL = bundle.url(forResource: "index", withExtension: "html", subdirectory: "terminal") {
            webView.loadFileURL(terminalURL, allowingReadAccessTo: terminalDir)
        } else {
            log.error("Terminal resources not found in bundle")
        }

        return container
    }

    static func dismantleNSView(_ container: TerminalHostView, coordinator: Coordinator) {
        coordinator.disconnect()
        coordinator.removeEventMonitor()
        if let webView = container.webView {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalBridge")
        }
        coordinator.webView = nil
        coordinator.hostView = nil
        container.webView = nil
    }

    func updateNSView(_ container: TerminalHostView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.isTerminalReady else {
            coordinator.pendingTheme = colorScheme
            return
        }
        let theme = colorScheme == .dark ? "dark" : "light"
        if coordinator.lastTheme != theme {
            coordinator.lastTheme = theme
            container.webView?.evaluateJavaScript("terminalBridge.setTheme('\(theme)')") { _, _ in }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var hostView: TerminalHostView?
        var isTerminalReady = false
        var lastTheme: String?
        var pendingTheme: ColorScheme?
        private var eventMonitor: Any?

        deinit { removeEventMonitor() }

        func removeEventMonitor() {
            if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        }

        /// Track clicks outside the terminal to clear logical focus and notify the host app.
        private func installEventMonitor() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self = self,
                      let webView = self.webView,
                      let hostView = self.hostView else { return event }
                if let window = webView.window {
                    let point = webView.convert(event.locationInWindow, from: nil)
                    if !webView.bounds.contains(point) {
                        hostView.hasTerminalFocus = false
                        // Tell host app to stop capturing keyboard events
                        webView.evaluateJavaScript("""
                            if (typeof terminalBridge !== 'undefined') {
                                var s = terminalBridge._socket;
                                if (s && s.readyState === WebSocket.OPEN) {
                                    s.send(JSON.stringify({ type: 'focus', focused: false }));
                                }
                            }
                        """) { _, _ in }
                    }
                }
                return event
            }
        }

        private func writeResponderDiagnostics() {
            guard let webView = webView else { return }

            let window = webView.window
            let fr = window?.firstResponder
            let frType = fr.map { String(describing: type(of: $0)) } ?? "nil"
            let windowType = window.map { String(describing: type(of: $0)) } ?? "nil"
            let isKey = window?.isKeyWindow ?? false

            let makeResult = window?.makeFirstResponder(webView) ?? false
            let frAfter = window?.firstResponder
            let frAfterType = frAfter.map { String(describing: type(of: $0)) } ?? "nil"

            var chain: [String] = []
            var resp: NSResponder? = webView
            while let r = resp, chain.count < 8 {
                chain.append(String(describing: type(of: r)))
                resp = r.nextResponder
            }

            let center = NSPoint(x: webView.bounds.midX, y: webView.bounds.midY)
            let hitView = webView.hitTest(center)
            let hitType = hitView.map { String(describing: type(of: $0)) } ?? "nil"

            // Build diagnostic lines with Swift interpolation FIRST
            var lines: [String] = []
            lines.append("--- RESPONDER DIAGNOSTICS ---")
            lines.append("window: \(windowType)  isKey: \(isKey)")
            lines.append("firstResponder BEFORE: \(frType)")
            lines.append("makeFirstResponder(webView): \(makeResult)  FR after: \(frAfterType)")
            lines.append("hitTest center: \(hitType)")
            lines.append("chain: \(chain.joined(separator: " > "))")
            lines.append("-----------------------------")

            // Escape for JS string literal, then write to terminal
            let text = lines.joined(separator: "\r\n")
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
            webView.evaluateJavaScript("terminalBridge.write('\\r\\n\\x1b[36m\(escaped)\\x1b[0m\\r\\n')") { _, _ in }
        }

        func disconnect() {
            webView?.evaluateJavaScript("terminalBridge.disconnect()") { _, _ in }
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let event = body["event"] as? String else { return }
            let data = body["data"] as? [String: Any] ?? [:]

            switch event {
            case "terminalReady":
                isTerminalReady = true

                if let theme = pendingTheme {
                    let name = theme == .dark ? "dark" : "light"
                    lastTheme = name
                    webView?.evaluateJavaScript("terminalBridge.setTheme('\(name)')") { _, _ in }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.webView?.evaluateJavaScript("terminalBridge.fit()") { _, _ in }
                }

                installEventMonitor()
                connectToWebSocket()

            case "connected":
                webView?.evaluateJavaScript("terminalBridge.focus()") { _, _ in }

            case "disconnected":
                let code = data["code"] as? Int ?? 0
                log.info("Terminal disconnected (code: \(code))")

            case "resize":
                break

            case "debug":
                let msg = data["message"] as? String ?? ""
                // JS click callback → set logical focus on the host view
                if msg.contains("[click]") {
                    hostView?.hasTerminalFocus = true
                    writeResponderDiagnostics()
                }

            default:
                break
            }
        }

        // MARK: - WebSocket

        private func connectToWebSocket() {
            guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.MichaelJancsy.ConjureDSP") else {
                showFallbackMessage(); return
            }
            let portFile = url.appendingPathComponent("terminal-server-port")
            guard let s = try? String(contentsOf: portFile, encoding: .utf8),
                  let port = UInt16(s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                showFallbackMessage(); return
            }
            webView?.evaluateJavaScript("terminalBridge.connect(\(port))") { _, _ in }
        }

        private func showFallbackMessage() {
            let msg = "\\r\\n  \\x1b[33mClaude Code terminal requires the ConjureDSP host app.\\x1b[0m\\r\\n  \\x1b[90mOpen ConjureDSP.app to enable the AI terminal.\\x1b[0m\\r\\n"
            webView?.evaluateJavaScript("terminalBridge.write('\(msg)')") { _, _ in }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log.error("Navigation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
