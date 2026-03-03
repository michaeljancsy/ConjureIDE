import Testing
import AppKit

struct SyntaxHighlighterTests {

    // MARK: - Helpers

    /// Apply highlighting and return the foreground color at the given character offset.
    private static func colorAt(
        offset: Int,
        in source: String,
        theme: PythonSyntaxHighlighter.Theme = .dark
    ) -> NSColor {
        let ts = NSTextStorage(string: source)
        let highlighter = PythonSyntaxHighlighter(theme: theme)
        highlighter.highlight(ts)
        let attrs = ts.attributes(at: offset, effectiveRange: nil)
        return attrs[.foregroundColor] as? NSColor ?? .clear
    }

    /// Check whether a color matches a theme color (compare RGB components).
    private static func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.deviceRGB),
              let b = b.usingColorSpace(.deviceRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    // MARK: - Keywords

    @Test func highlightsKeywords() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        // "def" at offset 0
        let color = Self.colorAt(offset: 0, in: "def foo():")
        #expect(Self.colorsMatch(color, theme.keyword),
                "'def' should be colored as a keyword")
    }

    @Test func highlightsReturnKeyword() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        let color = Self.colorAt(offset: 4, in: "    return 42")
        #expect(Self.colorsMatch(color, theme.keyword),
                "'return' should be colored as a keyword")
    }

    // MARK: - Strings

    @Test func highlightsSingleQuotedStrings() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        // "x = 'hello'" — the quote starts at offset 4
        let color = Self.colorAt(offset: 5, in: "x = 'hello'")
        #expect(Self.colorsMatch(color, theme.string),
                "Single-quoted string content should be colored as a string")
    }

    @Test func highlightsDoubleQuotedStrings() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        let source = #"name = "world""#
        let quoteIdx = source.distance(from: source.startIndex,
                                        to: source.firstIndex(of: "\"")!)
        let color = Self.colorAt(offset: quoteIdx + 1, in: source)
        #expect(Self.colorsMatch(color, theme.string),
                "Double-quoted string content should be colored as a string")
    }

    @Test func highlightsTripleQuotedStrings() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        let source = "x = \"\"\"multi\nline\"\"\""
        // offset 5 is inside the triple-quoted string
        let color = Self.colorAt(offset: 5, in: source)
        #expect(Self.colorsMatch(color, theme.string),
                "Triple-quoted string should be colored as a string")
    }

    // MARK: - Comments

    @Test func highlightsComments() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        let color = Self.colorAt(offset: 2, in: "# this is a comment")
        #expect(Self.colorsMatch(color, theme.comment),
                "Comment text should be colored as a comment")
    }

    @Test func commentsOverrideKeywords() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        // "def" inside a comment should be comment-colored, not keyword-colored
        let source = "# def not_a_function"
        let defOffset = 2  // the 'd' in 'def'
        let color = Self.colorAt(offset: defOffset, in: source)
        #expect(Self.colorsMatch(color, theme.comment),
                "'def' inside a comment should be colored as a comment, not a keyword")
    }

    // MARK: - Numbers

    @Test func highlightsNumbers() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        let color = Self.colorAt(offset: 4, in: "x = 42")
        #expect(Self.colorsMatch(color, theme.number),
                "Integer literal should be colored as a number")
    }

    @Test func highlightsFloats() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        let color = Self.colorAt(offset: 4, in: "x = 3.14")
        #expect(Self.colorsMatch(color, theme.number),
                "Float literal should be colored as a number")
    }

    // MARK: - Builtins

    @Test func highlightsBuiltins() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        let color = Self.colorAt(offset: 0, in: "print('hi')")
        #expect(Self.colorsMatch(color, theme.builtin),
                "'print' should be colored as a builtin")
    }

    // MARK: - Decorators

    @Test func highlightsDecorators() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        let color = Self.colorAt(offset: 0, in: "@staticmethod\ndef foo(): pass")
        #expect(Self.colorsMatch(color, theme.decorator),
                "Decorator should be colored as a decorator")
    }

    // MARK: - Def names

    @Test func highlightsDefNames() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        // "def process" — "process" starts at offset 4
        let color = Self.colorAt(offset: 4, in: "def process():")
        #expect(Self.colorsMatch(color, theme.defName),
                "Function name after 'def' should be colored as a defName")
    }

    // MARK: - Default text

    @Test func nonCodeTextGetsDefaultColor() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        // "x" at offset 0 is just a variable name — should be default color
        let color = Self.colorAt(offset: 0, in: "x = 42")
        #expect(Self.colorsMatch(color, theme.default),
                "Variable name should have default text color")
    }

    // MARK: - Dark vs Light themes

    @Test func darkAndLightThemesProduceDifferentColors() {
        let source = "def foo(): return 42"
        let darkColor = Self.colorAt(offset: 0, in: source, theme: .dark)
        let lightColor = Self.colorAt(offset: 0, in: source, theme: .light)
        #expect(!Self.colorsMatch(darkColor, lightColor),
                "Dark and light themes should produce different keyword colors")
    }

    @Test func lightThemeUsesLightKeywordColor() {
        let theme = PythonSyntaxHighlighter.Theme.light
        let color = Self.colorAt(offset: 0, in: "def foo():", theme: .light)
        #expect(Self.colorsMatch(color, theme.keyword),
                "'def' in light theme should use light keyword color")
    }

    // MARK: - Full script (default process.py)

    // MARK: - Rust Highlighter

    private static func rustColorAt(
        offset: Int,
        in source: String,
        theme: RustSyntaxHighlighter.Theme = .dark
    ) -> NSColor {
        let ts = NSTextStorage(string: source)
        let highlighter = RustSyntaxHighlighter(theme: theme)
        highlighter.highlight(ts)
        let attrs = ts.attributes(at: offset, effectiveRange: nil)
        return attrs[.foregroundColor] as? NSColor ?? .clear
    }

    @Test func rustHighlightsKeywords() {
        let theme = RustSyntaxHighlighter.Theme.dark
        let color = Self.rustColorAt(offset: 0, in: "fn main() {}")
        #expect(Self.colorsMatch(color, theme.keyword),
                "'fn' should be colored as a keyword")
    }

    @Test func rustHighlightsLetMut() {
        let theme = RustSyntaxHighlighter.Theme.dark
        let color = Self.rustColorAt(offset: 0, in: "let mut x = 5;")
        #expect(Self.colorsMatch(color, theme.keyword),
                "'let' should be colored as a keyword")
    }

    @Test func rustHighlightsTypes() {
        let theme = RustSyntaxHighlighter.Theme.dark
        // "x: f32" — "f32" starts at offset 3
        let color = Self.rustColorAt(offset: 3, in: "x: f32")
        #expect(Self.colorsMatch(color, theme.type),
                "'f32' should be colored as a type")
    }

    @Test func rustHighlightsStrings() {
        let theme = RustSyntaxHighlighter.Theme.dark
        // "let s = \"hello\"" — inside the string
        let source = #"let s = "hello""#
        let quoteIdx = (source as NSString).range(of: "\"").location
        let color = Self.rustColorAt(offset: quoteIdx + 1, in: source)
        #expect(Self.colorsMatch(color, theme.string),
                "String content should be colored as a string")
    }

    @Test func rustHighlightsLineComments() {
        let theme = RustSyntaxHighlighter.Theme.dark
        let color = Self.rustColorAt(offset: 3, in: "// this is a comment")
        #expect(Self.colorsMatch(color, theme.comment),
                "Comment text should be colored as a comment")
    }

    @Test func rustHighlightsBlockComments() {
        let theme = RustSyntaxHighlighter.Theme.dark
        let color = Self.rustColorAt(offset: 3, in: "/* block comment */")
        #expect(Self.colorsMatch(color, theme.comment),
                "Block comment should be colored as a comment")
    }

    @Test func rustHighlightsNumbers() {
        let theme = RustSyntaxHighlighter.Theme.dark
        let color = Self.rustColorAt(offset: 4, in: "x = 42;")
        #expect(Self.colorsMatch(color, theme.number),
                "Integer literal should be colored as a number")
    }

    @Test func rustHighlightsMacros() {
        let theme = RustSyntaxHighlighter.Theme.dark
        // "println!" — offset 0 is start of macro
        let color = Self.rustColorAt(offset: 0, in: "println!(\"hi\")")
        #expect(Self.colorsMatch(color, theme.macro),
                "'println!' should be colored as a macro")
    }

    @Test func rustHighlightsAttributes() {
        let theme = RustSyntaxHighlighter.Theme.dark
        let color = Self.rustColorAt(offset: 1, in: "#[no_mangle]")
        #expect(Self.colorsMatch(color, theme.attribute),
                "'#[no_mangle]' should be colored as an attribute")
    }

    @Test func rustHighlightsLifetimes() {
        let theme = RustSyntaxHighlighter.Theme.dark
        // "fn foo<'a>" — 'a starts at offset 7
        let color = Self.rustColorAt(offset: 8, in: "fn foo<'a>()")
        #expect(Self.colorsMatch(color, theme.lifetime),
                "Lifetime should be colored")
    }

    @Test func rustHighlightsFnNames() {
        let theme = RustSyntaxHighlighter.Theme.dark
        // "fn process()" — "process" starts at offset 3
        let color = Self.rustColorAt(offset: 3, in: "fn process()")
        #expect(Self.colorsMatch(color, theme.fnName),
                "Function name after 'fn' should be colored as fnName")
    }

    @Test func rustDarkAndLightThemesProduceDifferentColors() {
        let source = "fn main() {}"
        let darkColor = Self.rustColorAt(offset: 0, in: source, theme: .dark)
        let lightColor = Self.rustColorAt(offset: 0, in: source, theme: .light)
        #expect(!Self.colorsMatch(darkColor, lightColor),
                "Dark and light themes should produce different keyword colors")
    }

    @Test func rustCommentsOverrideKeywords() {
        let theme = RustSyntaxHighlighter.Theme.dark
        let source = "// fn not_a_function"
        let fnOffset = 3
        let color = Self.rustColorAt(offset: fnOffset, in: source)
        #expect(Self.colorsMatch(color, theme.comment),
                "'fn' inside a comment should be colored as a comment")
    }

    @Test func rustHighlightsFullTemplate() {
        let theme = RustSyntaxHighlighter.Theme.dark
        let source = """
        #[no_mangle]
        pub extern "C" fn process(input: *const f32, output: *mut f32) {
            let n = 42;
            // copy input to output
        }
        """
        let ts = NSTextStorage(string: source)
        let highlighter = RustSyntaxHighlighter(theme: theme)
        highlighter.highlight(ts)

        // "#[no_mangle]" at offset 0 → attribute
        let attrColor = ts.attributes(at: 1, effectiveRange: nil)[.foregroundColor] as? NSColor ?? .clear
        #expect(Self.colorsMatch(attrColor, theme.attribute), "Attribute should be highlighted")

        // "pub" → keyword
        let pubIdx = (source as NSString).range(of: "pub").location
        let pubColor = ts.attributes(at: pubIdx, effectiveRange: nil)[.foregroundColor] as? NSColor ?? .clear
        #expect(Self.colorsMatch(pubColor, theme.keyword), "'pub' should be keyword-colored")

        // "f32" → type
        let f32Idx = (source as NSString).range(of: "f32").location
        let f32Color = ts.attributes(at: f32Idx, effectiveRange: nil)[.foregroundColor] as? NSColor ?? .clear
        #expect(Self.colorsMatch(f32Color, theme.type), "'f32' should be type-colored")

        // "42" → number
        let numIdx = (source as NSString).range(of: "42").location
        let numColor = ts.attributes(at: numIdx, effectiveRange: nil)[.foregroundColor] as? NSColor ?? .clear
        #expect(Self.colorsMatch(numColor, theme.number), "'42' should be number-colored")

        // "// copy" → comment
        let commentIdx = (source as NSString).range(of: "// copy").location
        let commentColor = ts.attributes(at: commentIdx + 3, effectiveRange: nil)[.foregroundColor] as? NSColor ?? .clear
        #expect(Self.colorsMatch(commentColor, theme.comment), "Comment should be highlighted")
    }

    // MARK: - Protocol Conformance

    @Test func bothHighlightersConformToProtocol() {
        let python: any SyntaxHighlighter = PythonSyntaxHighlighter(theme: .dark)
        let rust: any SyntaxHighlighter = RustSyntaxHighlighter(theme: .dark)
        let ts = NSTextStorage(string: "test")
        python.highlight(ts)
        rust.highlight(ts)
        // If this compiles and runs, both conform to SyntaxHighlighter
    }

    // MARK: - Full Python script

    @Test func highlightsDefaultScript() {
        let theme = PythonSyntaxHighlighter.Theme.dark
        let source = """
        def process(inputs, outputs, frame_count, sample_rate):
            for ch in range(len(inputs)):
                outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.5
        """
        let ts = NSTextStorage(string: source)
        let highlighter = PythonSyntaxHighlighter(theme: theme)
        highlighter.highlight(ts)

        // "def" at offset 0 → keyword
        let defColor = ts.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor ?? .clear
        #expect(Self.colorsMatch(defColor, theme.keyword), "'def' should be keyword-colored")

        // "process" at offset 4 → defName
        let nameColor = ts.attributes(at: 4, effectiveRange: nil)[.foregroundColor] as? NSColor ?? .clear
        #expect(Self.colorsMatch(nameColor, theme.defName), "'process' should be defName-colored")

        // "for" in second line
        let forIdx = (source as NSString).range(of: "for").location
        let forColor = ts.attributes(at: forIdx, effectiveRange: nil)[.foregroundColor] as? NSColor ?? .clear
        #expect(Self.colorsMatch(forColor, theme.keyword), "'for' should be keyword-colored")

        // "range" → builtin
        let rangeIdx = (source as NSString).range(of: "range").location
        let rangeColor = ts.attributes(at: rangeIdx, effectiveRange: nil)[.foregroundColor] as? NSColor ?? .clear
        #expect(Self.colorsMatch(rangeColor, theme.builtin), "'range' should be builtin-colored")

        // "0.5" → number
        let numIdx = (source as NSString).range(of: "0.5").location
        let numColor = ts.attributes(at: numIdx, effectiveRange: nil)[.foregroundColor] as? NSColor ?? .clear
        #expect(Self.colorsMatch(numColor, theme.number), "'0.5' should be number-colored")
    }
}
