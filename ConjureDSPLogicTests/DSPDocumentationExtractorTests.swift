//
//  DSPDocumentationExtractorTests.swift
//  ConjureDSPLogicTests
//
//  PR #5: tests the regex-based docstring extractor used to build the
//  runtime API-reference appendix in `DSPDocumentation.swift`. Mirrors the
//  precedent in MCPProtocolTests and RuntimeErrorParserTests of copying
//  the type rather than importing the extension target.
//

import Foundation
import Testing

// MARK: - Copy of the production extractor

private enum DocExtractor {
    struct Symbol: Equatable {
        let name: String
        let signature: String
        let docstring: String
    }

    static func extractPython(content: String) -> [Symbol] {
        // `[^\n]*:` matches up to the end-of-line colon. Earlier `[^:]*:`
        // bug stopped at the first colon, missing function signatures like
        // `def foo(x: int) -> int:` which contain a colon in the args.
        let pattern = #"(?m)^((?:def|class)\s+(\w+)[^\n]*:)\s*\n\s+(?:\"\"\"|''')([\s\S]*?)(?:\"\"\"|''')"#
        return runRegex(pattern: pattern, in: content) { match, source in
            guard let sigRange = Range(match.range(at: 1), in: source),
                  let nameRange = Range(match.range(at: 2), in: source),
                  let docRange = Range(match.range(at: 3), in: source) else {
                return nil
            }
            return Symbol(
                name: String(source[nameRange]),
                signature: String(source[sigRange]),
                docstring: dedent(String(source[docRange]))
            )
        }
    }

    static func extractRust(content: String) -> [Symbol] {
        let pattern = #"((?:^[ \t]*///[^\n]*\n)+)[ \t]*((?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?(?:extern\s+\"[^\"]+\"\s+)?(?:fn|struct|trait|enum)\s+(\w+)[^{;\n]*)"#
        return runRegex(pattern: pattern, in: content) { match, source in
            guard let docRange = Range(match.range(at: 1), in: source),
                  let sigRange = Range(match.range(at: 2), in: source),
                  let nameRange = Range(match.range(at: 3), in: source) else {
                return nil
            }
            let raw = String(source[docRange])
            let cleaned = raw
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    let trimmed = line.drop { $0.isWhitespace }
                    guard trimmed.hasPrefix("///") else { return String(line) }
                    let afterSlash = trimmed.dropFirst(3)
                    if afterSlash.first == " " {
                        return String(afterSlash.dropFirst())
                    }
                    return String(afterSlash)
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip private (non-pub) symbols. The regex above accepts them
            // because `pub...?` is optional; we filter post-match by
            // checking the signature prefix.
            let sig = String(source[sigRange]).trimmingCharacters(in: .whitespaces)
            guard sig.hasPrefix("pub") else { return nil }
            return Symbol(
                name: String(source[nameRange]),
                signature: sig,
                docstring: cleaned
            )
        }
    }

    private static func runRegex<T>(
        pattern: String,
        in source: String,
        transform: (NSTextCheckingResult, String) -> T?
    ) -> [T] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        var results: [T] = []
        re.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match else { return }
            if let item = transform(match, source) { results.append(item) }
        }
        return results
    }

    private static func dedent(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        var minIndent = Int.max
        for (idx, line) in lines.enumerated() where idx > 0 {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.isEmpty { continue }
            let indent = line.count - trimmed.count
            if indent < minIndent { minIndent = indent }
        }
        if minIndent == Int.max { minIndent = 0 }
        let stripped: [String] = lines.enumerated().map { idx, line in
            if idx == 0 { return String(line).trimmingCharacters(in: .whitespaces) }
            if line.count <= minIndent { return "" }
            return String(line.dropFirst(minIndent))
        }
        return stripped.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Tests

@Suite("DSP documentation extractor")
struct DSPDocumentationExtractorTests {

    @Test("Python: single function with docstring")
    func pythonSingleFunction() {
        let source = #"""
        def db_to_gain(db: float) -> float:
            """Convert decibels to a linear gain factor."""
            return 10.0 ** (db / 20.0)
        """#
        let symbols = DocExtractor.extractPython(content: source)
        #expect(symbols.count == 1)
        if let s = symbols.first {
            #expect(s.name == "db_to_gain")
            #expect(s.signature.contains("def db_to_gain"))
            #expect(s.docstring == "Convert decibels to a linear gain factor.")
        }
    }

    @Test("Python: function signature with colons in args still matches")
    func pythonColonsInArgs() {
        // Earlier `[^:]*:` regex bug stopped at the first colon. Make
        // sure the regression is locked in.
        let source = #"""
        def with_typed_args(a: int, b: float = 1.0) -> str:
            """Returns a string."""
            return ""
        """#
        let symbols = DocExtractor.extractPython(content: source)
        #expect(symbols.count == 1)
    }

    @Test("Python: class with docstring")
    func pythonClass() {
        let source = #"""
        class Biquad:
            """Stateful biquad filter."""
            pass
        """#
        let symbols = DocExtractor.extractPython(content: source)
        #expect(symbols.count == 1)
        if let s = symbols.first {
            #expect(s.name == "Biquad")
        }
    }

    @Test("Python: function without docstring is skipped")
    func pythonNoDocstring() {
        let source = "def undocumented():\n    return 42\n"
        let symbols = DocExtractor.extractPython(content: source)
        #expect(symbols.isEmpty)
    }

    @Test("Python: triple-single-quote docstring works")
    func pythonTripleSingle() {
        let source = "def foo():\n    '''Triple-single docstring.'''\n    pass\n"
        let symbols = DocExtractor.extractPython(content: source)
        #expect(symbols.count == 1)
        if let s = symbols.first {
            #expect(s.docstring == "Triple-single docstring.")
        }
    }

    @Test("Rust: pub fn with /// doc comment")
    func rustPubFn() {
        let source = """
        /// Convert decibels to a linear gain factor.
        pub fn db_to_gain(db: f32) -> f32 {
            10.0_f32.powf(db / 20.0)
        }
        """
        let symbols = DocExtractor.extractRust(content: source)
        #expect(symbols.count == 1)
        if let s = symbols.first {
            #expect(s.name == "db_to_gain")
            #expect(s.docstring == "Convert decibels to a linear gain factor.")
        }
    }

    @Test("Rust: pub struct")
    func rustPubStruct() {
        let source = """
        /// Stateful biquad filter.
        pub struct Biquad {
            state: [f32; 2],
        }
        """
        let symbols = DocExtractor.extractRust(content: source)
        #expect(symbols.count == 1)
        if let s = symbols.first {
            #expect(s.name == "Biquad")
        }
    }

    @Test("Rust: undocumented pub fn is skipped")
    func rustUndocumented() {
        let source = "pub fn undocumented() -> i32 { 42 }\n"
        let symbols = DocExtractor.extractRust(content: source)
        #expect(symbols.isEmpty)
    }

    @Test("Rust: private fn (no pub) is skipped")
    func rustPrivate() {
        let source = """
        /// Private helper.
        fn private_helper() {}
        """
        let symbols = DocExtractor.extractRust(content: source)
        #expect(symbols.isEmpty)
    }

    @Test("Rust: pub(crate) is accepted")
    func rustPubCrate() {
        let source = """
        /// Crate-private fn with rich docs.
        pub(crate) fn crate_only() {}
        """
        let symbols = DocExtractor.extractRust(content: source)
        #expect(symbols.count == 1)
        if let s = symbols.first {
            #expect(s.name == "crate_only")
        }
    }
}
