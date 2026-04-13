import AppKit

final class RustSyntaxHighlighter: SyntaxHighlighter {

    struct Theme {
        var keyword: NSColor
        var type: NSColor
        var string: NSColor
        var comment: NSColor
        var number: NSColor
        var macro: NSColor
        var attribute: NSColor
        var lifetime: NSColor
        var fnName: NSColor
        var `default`: NSColor
        var font: NSFont

        static var dark: Theme {
            Theme(
                keyword: NSColor(red: 1.0, green: 0.478, blue: 0.698, alpha: 1),     // #FF7AB2
                type: NSColor(red: 0.392, green: 0.831, blue: 0.659, alpha: 1),       // #64D4A8
                string: NSColor(red: 0.988, green: 0.416, blue: 0.365, alpha: 1),     // #FC6A5D
                comment: NSColor(red: 0.424, green: 0.475, blue: 0.525, alpha: 1),    // #6C7986
                number: NSColor(red: 0.816, green: 0.749, blue: 0.412, alpha: 1),     // #D0BF69
                macro: NSColor(red: 0.698, green: 0.506, blue: 0.922, alpha: 1),      // #B281EB
                attribute: NSColor(red: 0.698, green: 0.506, blue: 0.922, alpha: 1),  // #B281EB
                lifetime: NSColor(red: 0.988, green: 0.416, blue: 0.365, alpha: 1),   // #FC6A5D
                fnName: NSColor(red: 0.255, green: 0.631, blue: 0.753, alpha: 1),     // #41A1C0
                default: NSColor.white,
                font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            )
        }

        static var light: Theme {
            Theme(
                keyword: NSColor(red: 0.608, green: 0.137, blue: 0.576, alpha: 1),    // #9B2393
                type: NSColor(red: 0.043, green: 0.459, blue: 0.373, alpha: 1),       // #0B755F
                string: NSColor(red: 0.769, green: 0.102, blue: 0.086, alpha: 1),     // #C41A16
                comment: NSColor(red: 0.365, green: 0.424, blue: 0.475, alpha: 1),    // #5D6C79
                number: NSColor(red: 0.110, green: 0.0, blue: 0.812, alpha: 1),       // #1C00CF
                macro: NSColor(red: 0.224, green: 0.0, blue: 0.627, alpha: 1),        // #3900A0
                attribute: NSColor(red: 0.224, green: 0.0, blue: 0.627, alpha: 1),    // #3900A0
                lifetime: NSColor(red: 0.769, green: 0.102, blue: 0.086, alpha: 1),   // #C41A16
                fnName: NSColor(red: 0.059, green: 0.408, blue: 0.627, alpha: 1),     // #0F68A0
                default: NSColor.black,
                font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            )
        }
    }

    private let theme: Theme
    private let patterns: [(NSRegularExpression, NSColor)]

    init(theme: Theme) {
        self.theme = theme

        var compiled: [(NSRegularExpression, NSColor)] = []

        let defs: [(String, NSColor, NSRegularExpression.Options)] = [
            // Numbers (int, float, hex, binary, octal, with optional type suffix)
            (#"\b\d[\d_]*(\.\d[\d_]*)?([eE][+-]?\d[\d_]*)?(f32|f64|i8|i16|i32|i64|u8|u16|u32|u64|usize|isize)?\b"#, theme.number, []),
            (#"\b0[xX][0-9a-fA-F_]+\b"#, theme.number, []),
            (#"\b0[bB][01_]+\b"#, theme.number, []),
            (#"\b0[oO][0-7_]+\b"#, theme.number, []),

            // Keywords
            (#"\b(fn|let|mut|pub|extern|unsafe|static|const|struct|enum|impl|trait|use|mod|for|while|loop|if|else|match|return|break|continue|as|in|where|type|self|Self|super|crate|true|false|ref|move|async|await|dyn|yield)\b"#, theme.keyword, []),

            // Primitive types
            (#"\b(i8|i16|i32|i64|i128|u8|u16|u32|u64|u128|f32|f64|usize|isize|bool|char|str|String|Vec|Option|Result|Box|Rc|Arc|Cell|RefCell)\b"#, theme.type, []),

            // Lifetimes ('a, 'static, etc.) — before strings so 'a isn't treated as char literal
            (#"'\w+"#, theme.lifetime, []),

            // Attributes (#[...] and #![...])
            (#"#!?\[[^\]]*\]"#, theme.attribute, []),

            // Macro invocations (word!)
            (#"\b\w+!"#, theme.macro, []),

            // Function names after fn
            (#"(?<=\bfn\s)\w+"#, theme.fnName, []),

            // Strings (double-quoted, with escape support)
            (#""(?:[^"\\]|\\.)*""#, theme.string, []),

            // Raw strings (r"..." — simplified, doesn't handle r#"..."# delimiters)
            ("r\"[^\"]*\"", theme.string, []),

            // Char literals
            (#"'[^'\\]'"#, theme.string, []),
            (#"'\\.[^']*'"#, theme.string, []),

            // Line comments — highest priority
            (#"//[^\n]*"#, theme.comment, []),

            // Block comments
            (#"/\*[\s\S]*?\*/"#, theme.comment, []),
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
