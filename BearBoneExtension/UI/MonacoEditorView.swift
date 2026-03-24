import os
import SwiftUI
import WebKit

private let log = Logger(subsystem: "com.MichaelJancsy.BearBone.BearBoneExtension", category: "MonacoEditor")

struct MonacoEditorView: NSViewRepresentable {
    @Binding var text: String
    var colorScheme: ColorScheme
    var language: ScriptLanguage = .python
    var isEditable: Bool = true
    var extensionBundle: Bundle

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "contentChanged")
        contentController.add(context.coordinator, name: "editorReady")
        config.userContentController = contentController

        // Allow local file access
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // Transparent background to blend with SwiftUI
        webView.setValue(false, forKey: "drawsBackground")

        webView.setAccessibilityIdentifier("scriptEditor")

        // Load Monaco HTML from the extension bundle
        if let monacoDir = extensionBundle.url(forResource: "monaco", withExtension: nil),
           let monacoURL = extensionBundle.url(forResource: "index", withExtension: "html", subdirectory: "monaco") {
            log.info("Loading Monaco from \(monacoURL.path, privacy: .public)")
            webView.loadFileURL(monacoURL, allowingReadAccessTo: monacoDir)
        } else {
            log.error("Monaco resources not found in bundle \(extensionBundle.bundlePath, privacy: .public)")
        }

        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        log.info("dismantleNSView called (isEditorReady=\(coordinator.isEditorReady))")
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "contentChanged")
        controller.removeScriptMessageHandler(forName: "editorReady")
        coordinator.webView = nil
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator

        // Update stored properties for when editor becomes ready
        coordinator.pendingLanguage = language
        coordinator.pendingTheme = colorScheme
        coordinator.pendingReadOnly = !isEditable

        guard coordinator.isEditorReady else {
            // Queue initial content for after editor loads
            coordinator.pendingContent = text
            return
        }

        // Update theme if changed
        let theme = colorScheme == .dark ? "vs-dark" : "vs"
        if coordinator.lastTheme != theme {
            coordinator.lastTheme = theme
            webView.evaluateJavaScript("bridge.setTheme('\(theme)')") { _, _ in }
        }

        // Update language if changed
        let monacoLang = language == .rust ? "rust" : "python"
        if coordinator.lastLanguage != monacoLang {
            coordinator.lastLanguage = monacoLang
            webView.evaluateJavaScript("bridge.setLanguage('\(monacoLang)')") { _, _ in }
        }

        // Update read-only state
        let readOnly = !isEditable
        if coordinator.lastReadOnly != readOnly {
            coordinator.lastReadOnly = readOnly
            webView.evaluateJavaScript("bridge.setReadOnly(\(readOnly))") { _, _ in }
        }

        // Only update content if it changed externally (not from user typing in Monaco)
        if text != coordinator.lastContent && !coordinator.isUpdatingFromJS {
            coordinator.lastContent = text
            let escaped = text.jsEscaped
            webView.evaluateJavaScript("bridge.setContent(\"\(escaped)\")") { _, _ in }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var text: Binding<String>
        weak var webView: WKWebView?

        var isEditorReady = false
        var isUpdatingFromJS = false

        // Track last-sent values to avoid redundant JS calls
        var lastContent: String = ""
        var lastTheme: String?
        var lastLanguage: String?
        var lastReadOnly: Bool?

        // Queued state for before editor is ready
        var pendingContent: String?
        var pendingLanguage: ScriptLanguage = .python
        var pendingTheme: ColorScheme = .dark
        var pendingReadOnly: Bool = false

        init(text: Binding<String>) {
            self.text = text
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "editorReady":
                log.info("Monaco editor ready")
                isEditorReady = true
                applyPendingState()

            case "contentChanged":
                guard let newText = message.body as? String else { return }
                lastContent = newText
                isUpdatingFromJS = true
                text.wrappedValue = newText
                isUpdatingFromJS = false

            default:
                break
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log.info("WKWebView didFinish navigation")
            // Page loaded — initialize Monaco with options
            let theme = pendingTheme == .dark ? "vs-dark" : "vs"
            let lang = pendingLanguage == .rust ? "rust" : "python"
            let content = (pendingContent ?? text.wrappedValue).jsEscaped

            let initScript = """
                try {
                    bridge.init({
                        content: "\(content)",
                        language: "\(lang)",
                        theme: "\(theme)",
                        readOnly: \(pendingReadOnly)
                    });
                    'ok';
                } catch(e) {
                    'ERROR: ' + e.message + ' | ' + e.stack;
                }
            """
            log.info("Calling bridge.init (content length=\(content.count), lang=\(lang, privacy: .public))")
            webView.evaluateJavaScript(initScript) { result, error in
                if let error {
                    log.error("bridge.init JS error: \(error.localizedDescription, privacy: .public)")
                } else if let result = result as? String, result.hasPrefix("ERROR:") {
                    log.error("bridge.init threw: \(result, privacy: .public)")
                } else {
                    log.info("bridge.init JS succeeded")
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log.error("WKWebView navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log.error("WKWebView provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            log.error("WKWebView content process terminated, reloading")
            isEditorReady = false
            webView.reload()
        }

        private func applyPendingState() {
            guard let webView else { return }

            let theme = pendingTheme == .dark ? "vs-dark" : "vs"
            lastTheme = theme
            webView.evaluateJavaScript("bridge.setTheme('\(theme)')") { _, _ in }

            let lang = pendingLanguage == .rust ? "rust" : "python"
            lastLanguage = lang
            webView.evaluateJavaScript("bridge.setLanguage('\(lang)')") { _, _ in }

            lastReadOnly = pendingReadOnly
            webView.evaluateJavaScript("bridge.setReadOnly(\(pendingReadOnly))") { _, _ in }

            let content = pendingContent ?? text.wrappedValue
            lastContent = content
            let escaped = content.jsEscaped
            webView.evaluateJavaScript("bridge.setContent(\"\(escaped)\")") { _, _ in }
            pendingContent = nil
        }
    }
}

// MARK: - Error markers

extension MonacoEditorView {
    /// Set error/warning markers in the editor.
    /// Call via the coordinator's webView after obtaining it.
    struct Marker {
        let startLine: Int
        let message: String
        let severity: String  // "error" or "warning"
    }
}

// MARK: - String escaping for JavaScript

private extension String {
    /// Escapes a string for safe embedding in a JavaScript double-quoted string literal.
    var jsEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
