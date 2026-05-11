import Foundation

/// PR #5: regex-based extractor for Python and Rust docstrings.
///
/// Reads library source text and produces a Markdown API-reference
/// appendix. The extractor is intentionally regex-only (no `ast.parse`)
/// because the documentation MCP path can be invoked before any Python
/// preset has been loaded — `PYTHONHOME` isn't guaranteed set, so
/// `import ast` would fail. Pure-Swift regex sidesteps this entirely.
///
/// Used by `DSPDocumentation` to append an "API reference" section to
/// hand-curated topic strings (filters, oscillators, delays, etc.).
/// Purely additive: if extraction fails (source missing, regex doesn't
/// match), the hand-curated content still ships unchanged.
///
/// Source-path wiring lives in `DSPDocumentation`; this struct only
/// understands source text, which keeps it pure and easy to unit-test.
public enum DSPDocumentationExtractor {
    public struct Symbol: Equatable {
        public let name: String
        public let signature: String  // `def foo(a, b):` or `pub fn foo(...)`
        public let docstring: String  // raw text, with leading whitespace stripped per line

        public init(name: String, signature: String, docstring: String) {
            self.name = name
            self.signature = signature
            self.docstring = docstring
        }
    }

    /// Extracts top-level functions, classes, and their docstrings from a
    /// Python source file. Methods inside classes are NOT extracted
    /// separately — the class's docstring captures them.
    ///
    /// Patterns recognized:
    ///   def NAME(args):
    ///       """docstring..."""
    ///
    ///   class NAME[(base)]:
    ///       """docstring..."""
    public static func extractPython(content: String) -> [Symbol] {
        // Matches `def NAME(args):` OR `class NAME[...]:` at column 0,
        // followed by an indented triple-quoted docstring on the next
        // non-blank line.
        //
        // The `[^\n]*:` after the name matches anything up to the
        // end-of-line colon — using `[^:]*:` would stop at the FIRST
        // colon, which is wrong for `def foo(x: int) -> int:` where the
        // arg list contains its own colons.
        //
        // Capture groups:
        //   1: full signature line (e.g. `def foo(a, b: int) -> str:`)
        //   2: name
        //   3: docstring body (between the triple quotes)
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
                docstring: dedentDocstring(String(source[docRange]))
            )
        }
    }

    /// Extracts `pub fn`/`pub struct`/`pub trait`/`pub enum` symbols and
    /// their preceding `///` doc-comment block from a Rust source file.
    ///
    /// The doc comment must immediately precede the symbol (one or more
    /// `///` lines, no blank lines or other comments between).
    public static func extractRust(content: String) -> [Symbol] {
        // One or more `///` lines, then a `pub fn|struct|trait|enum NAME`
        // declaration. The trailing pattern stops at the first `{`, `;`,
        // or newline so we don't drag in the entire function body.
        //
        // Capture groups:
        //   1: full doc comment block (lines starting with `///`)
        //   2: signature up to `{` / `;` / newline
        //   3: symbol name
        let pattern = #"((?:^[ \t]*///[^\n]*\n)+)[ \t]*((?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?(?:extern\s+\"[^\"]+\"\s+)?(?:fn|struct|trait|enum)\s+(\w+)[^{;\n]*)"#
        return runRegex(pattern: pattern, in: content) { match, source in
            guard let docRange = Range(match.range(at: 1), in: source),
                  let sigRange = Range(match.range(at: 2), in: source),
                  let nameRange = Range(match.range(at: 3), in: source) else {
                return nil
            }
            let raw = String(source[docRange])
            // Strip leading `///` + optional space from each line.
            let cleaned = raw
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    let trimmed = line.drop { $0.isWhitespace }
                    guard trimmed.hasPrefix("///") else { return String(line) }
                    let afterSlash = trimmed.dropFirst(3)
                    // Strip exactly one leading space if present (`/// foo` → `foo`).
                    if afterSlash.first == " " {
                        return String(afterSlash.dropFirst())
                    }
                    return String(afterSlash)
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Symbol(
                name: String(source[nameRange]),
                signature: String(source[sigRange]).trimmingCharacters(in: .whitespaces),
                docstring: cleaned
            )
        }
    }

    /// Renders a list of symbols as a Markdown section.
    public static func renderMarkdown(_ symbols: [Symbol]) -> String {
        symbols.map { sym in
            """
            ### \(sym.name)

            ```
            \(sym.signature)
            ```

            \(sym.docstring)
            """
        }.joined(separator: "\n\n")
    }

    // MARK: - Internals

    private static func runRegex<T>(
        pattern: String,
        in source: String,
        transform: (NSTextCheckingResult, String) -> T?
    ) -> [T] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(source.startIndex..., in: source)
        var results: [T] = []
        re.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match else { return }
            if let item = transform(match, source) {
                results.append(item)
            }
        }
        return results
    }

    /// Strips the common leading whitespace from a multi-line docstring
    /// body (Python `inspect.cleandoc`-equivalent for our purposes).
    private static func dedentDocstring(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        // Compute common indent across non-blank lines after the first.
        var minIndent = Int.max
        for (idx, line) in lines.enumerated() where idx > 0 {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.isEmpty { continue }  // blank line — ignored for min
            let indent = line.count - trimmed.count
            if indent < minIndent { minIndent = indent }
        }
        if minIndent == Int.max { minIndent = 0 }

        // Strip `minIndent` chars from each non-first line.
        let stripped: [String] = lines.enumerated().map { idx, line in
            if idx == 0 { return String(line).trimmingCharacters(in: .whitespaces) }
            if line.count <= minIndent { return "" }
            return String(line.dropFirst(minIndent))
        }
        return stripped.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
