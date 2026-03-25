import SwiftUI
import AppKit

struct HighlightedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var colorScheme: ColorScheme
    var language: ScriptLanguage = .python
    var isEditable: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .textBackgroundColor

        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator

        textView.setAccessibilityIdentifier("scriptEditor")

        textView.string = text
        // Apply initial highlighting
        if let ts = textView.textStorage {
            context.coordinator.highlighter.highlight(ts)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        textView.isEditable = isEditable

        // Update highlighter if color scheme or language changed
        let newHighlighter = Self.makeHighlighter(colorScheme: colorScheme, language: language)
        context.coordinator.highlighter = newHighlighter

        // Only update text if it changed externally (not from user typing)
        if textView.string != text {
            textView.string = text

            // Scroll to bottom during streaming (read-only external updates)
            if !isEditable {
                textView.scrollToEndOfDocument(nil)
            }
        }

        // Debounce highlighting during rapid external updates (e.g. streaming)
        if !isEditable {
            context.coordinator.scheduleHighlight(textStorage: textView.textStorage)
        } else {
            // Immediate highlighting for theme changes or single external updates
            if let ts = textView.textStorage {
                context.coordinator.isHighlighting = true
                newHighlighter.highlight(ts)
                context.coordinator.isHighlighting = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, highlighter: Self.makeHighlighter(colorScheme: colorScheme, language: language))
    }

    private static func makeHighlighter(colorScheme: ColorScheme, language: ScriptLanguage) -> any SyntaxHighlighter {
        switch language {
        case .python:
            let theme: PythonSyntaxHighlighter.Theme = colorScheme == .dark ? .dark : .light
            return PythonSyntaxHighlighter(theme: theme)
        case .rust:
            let theme: RustSyntaxHighlighter.Theme = colorScheme == .dark ? .dark : .light
            return RustSyntaxHighlighter(theme: theme)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var text: Binding<String>
        var highlighter: any SyntaxHighlighter
        var isHighlighting = false
        private var highlightTimer: Timer?

        init(text: Binding<String>, highlighter: any SyntaxHighlighter) {
            self.text = text
            self.highlighter = highlighter
        }

        /// Debounced highlighting for streaming updates.
        func scheduleHighlight(textStorage: NSTextStorage?) {
            highlightTimer?.invalidate()
            highlightTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) {
                [weak self] _ in
                guard let self, let ts = textStorage else { return }
                self.isHighlighting = true
                self.highlighter.highlight(ts)
                self.isHighlighting = false
            }
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isHighlighting else { return }
            text.wrappedValue = textView.string
        }

        // MARK: - NSTextStorageDelegate

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            guard !isHighlighting else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isHighlighting = true
                self.highlighter.highlight(textStorage)
                self.isHighlighting = false
            }
        }
    }
}
