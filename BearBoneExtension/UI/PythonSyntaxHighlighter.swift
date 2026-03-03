import AppKit

final class PythonSyntaxHighlighter: SyntaxHighlighter {

    struct Theme {
        var keyword: NSColor
        var builtin: NSColor
        var string: NSColor
        var comment: NSColor
        var number: NSColor
        var decorator: NSColor
        var defName: NSColor
        var `default`: NSColor
        var font: NSFont

        static var dark: Theme {
            Theme(
                keyword: NSColor(red: 1.0, green: 0.478, blue: 0.698, alpha: 1),     // #FF7AB2
                builtin: NSColor(red: 0.698, green: 0.506, blue: 0.922, alpha: 1),    // #B281EB
                string: NSColor(red: 0.988, green: 0.416, blue: 0.365, alpha: 1),     // #FC6A5D
                comment: NSColor(red: 0.424, green: 0.475, blue: 0.525, alpha: 1),    // #6C7986
                number: NSColor(red: 0.816, green: 0.749, blue: 0.412, alpha: 1),     // #D0BF69
                decorator: NSColor(red: 0.698, green: 0.506, blue: 0.922, alpha: 1),  // #B281EB
                defName: NSColor(red: 0.255, green: 0.631, blue: 0.753, alpha: 1),    // #41A1C0
                default: NSColor.white,
                font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            )
        }

        static var light: Theme {
            Theme(
                keyword: NSColor(red: 0.608, green: 0.137, blue: 0.576, alpha: 1),    // #9B2393
                builtin: NSColor(red: 0.224, green: 0.0, blue: 0.627, alpha: 1),      // #3900A0
                string: NSColor(red: 0.769, green: 0.102, blue: 0.086, alpha: 1),     // #C41A16
                comment: NSColor(red: 0.365, green: 0.424, blue: 0.475, alpha: 1),    // #5D6C79
                number: NSColor(red: 0.110, green: 0.0, blue: 0.812, alpha: 1),       // #1C00CF
                decorator: NSColor(red: 0.224, green: 0.0, blue: 0.627, alpha: 1),    // #3900A0
                defName: NSColor(red: 0.059, green: 0.408, blue: 0.627, alpha: 1),    // #0F68A0
                default: NSColor.black,
                font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            )
        }
    }

    private let theme: Theme
    private let patterns: [(NSRegularExpression, NSColor)]

    init(theme: Theme) {
        self.theme = theme

        // Build patterns in application order. Later patterns override earlier ones,
        // so comments and strings go last to prevent keyword coloring inside them.
        var compiled: [(NSRegularExpression, NSColor)] = []

        let defs: [(String, NSColor, NSRegularExpression.Options)] = [
            // Numbers (int, float, hex)
            (#"\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#, theme.number, []),
            (#"\b0[xX][0-9a-fA-F]+\b"#, theme.number, []),

            // Keywords
            (#"\b(and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield|True|False|None)\b"#, theme.keyword, []),

            // Builtin functions
            (#"\b(print|range|len|int|float|str|list|dict|tuple|set|type|isinstance|enumerate|zip|map|filter|sorted|abs|min|max|sum|round|open|super|property|staticmethod|classmethod|hasattr|getattr|setattr|vars|dir|id|repr|hash|callable|iter|next|reversed|slice|format|input|ord|chr|hex|oct|bin|bool|bytes|bytearray|memoryview|complex|frozenset|object|all|any|pow|divmod|globals|locals|compile|exec|eval|breakpoint|__import__|isinstance|issubclass)\b"#, theme.builtin, []),

            // Decorators
            (#"@\w+"#, theme.decorator, []),

            // Function/class names after def/class
            (#"(?<=\bdef\s)\w+"#, theme.defName, []),
            (#"(?<=\bclass\s)\w+"#, theme.defName, []),

            // Triple-quoted strings (must come before single-line strings)
            (#""{3}[\s\S]*?"{3}"#, theme.string, []),
            (#"'{3}[\s\S]*?'{3}"#, theme.string, []),

            // Single-line strings (f-strings included)
            (#"f?"(?:[^"\\\n]|\\.)*""#, theme.string, []),
            (#"f?'(?:[^'\\\n]|\\.)*'"#, theme.string, []),

            // Comments — last, highest priority
            (#"#[^\n]*"#, theme.comment, []),
        ]

        for (pattern, color, options) in defs {
            if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
                compiled.append((regex, color))
            }
        }

        self.patterns = compiled
    }

    func highlight(_ textStorage: NSTextStorage) {
        let source = textStorage.string
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        guard fullRange.length > 0 else { return }

        textStorage.addAttributes([
            .foregroundColor: theme.default,
            .font: theme.font,
        ], range: fullRange)

        for (regex, color) in patterns {
            regex.enumerateMatches(in: source, range: fullRange) { match, _, _ in
                guard let range = match?.range else { return }
                textStorage.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }
}
