import AppKit

/// Common interface for language-specific syntax highlighters.
protocol SyntaxHighlighter {
    func highlight(_ textStorage: NSTextStorage)
}
