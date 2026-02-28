import SwiftUI
import AppKit

struct HighlightedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var colorScheme: ColorScheme

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

        // Update highlighter theme if color scheme changed
        let newHighlighter = Self.makeHighlighter(colorScheme: colorScheme)
        context.coordinator.highlighter = newHighlighter

        // Only update text if it changed externally (not from user typing)
        if textView.string != text {
            textView.string = text
        }

        // Re-highlight (handles theme change or external text change)
        if let ts = textView.textStorage {
            context.coordinator.isHighlighting = true
            newHighlighter.highlight(ts)
            context.coordinator.isHighlighting = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, highlighter: Self.makeHighlighter(colorScheme: colorScheme))
    }

    private static func makeHighlighter(colorScheme: ColorScheme) -> PythonSyntaxHighlighter {
        let theme: PythonSyntaxHighlighter.Theme = colorScheme == .dark ? .dark : .light
        return PythonSyntaxHighlighter(theme: theme)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var text: Binding<String>
        var highlighter: PythonSyntaxHighlighter
        var isHighlighting = false

        init(text: Binding<String>, highlighter: PythonSyntaxHighlighter) {
            self.text = text
            self.highlighter = highlighter
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
