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
