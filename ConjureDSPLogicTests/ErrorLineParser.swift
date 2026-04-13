import Foundation

/// Extracts line/column information from DSP script error messages
/// to enable inline Monaco editor markers.
struct ErrorLineParser {

    struct ParsedMarker: Equatable {
        let line: Int        // 1-based
        let column: Int?     // 1-based, optional
        let message: String
        let severity: String // "error" or "warning"
    }

    /// Parse an error string and extract line-level markers.
    /// Returns at least one marker (line 1 fallback if no line info found).
    static func parse(_ error: String, language: ScriptLanguage) -> [ParsedMarker] {
        switch language {
        case .python:
            return parsePython(error)
        case .rust:
            return parseRust(error)
        }
    }

    // MARK: - Python

    /// Python errors from PyO3 debug format typically contain `(line N)` or `(line N, offset M)`.
    /// Example: `"python_home: ...\nscript_path: ...\nerror: SyntaxError: expected ':' (line 5)"`
    /// Example: `"Python process error: ZeroDivisionError: division by zero"`
    private static func parsePython(_ error: String) -> [ParsedMarker] {
        // Extract the error portion after "error: " if present (load errors have preamble)
        let errorPortion: String
        if let range = error.range(of: "error: ", options: .backwards) {
            errorPortion = String(error[range.upperBound...])
        } else {
            errorPortion = error
        }

        // Try to extract line number: (line N) or (line N, offset M)
        let linePattern = #"\(line (\d+)(?:, offset (\d+))?\)"#
        if let regex = try? NSRegularExpression(pattern: linePattern),
           let match = regex.firstMatch(in: errorPortion, range: NSRange(errorPortion.startIndex..., in: errorPortion)) {
            let lineRange = match.range(at: 1)
            if let lineSwiftRange = Range(lineRange, in: errorPortion),
               let line = Int(errorPortion[lineSwiftRange]) {
                var column: Int?
                if match.numberOfRanges > 2 {
                    let colRange = match.range(at: 2)
                    if colRange.location != NSNotFound,
                       let colSwiftRange = Range(colRange, in: errorPortion) {
                        column = Int(errorPortion[colSwiftRange])
                    }
                }
                // Clean up the message: use the error portion without the preamble
                let message = errorPortion.trimmingCharacters(in: .whitespacesAndNewlines)
                return [ParsedMarker(line: line, column: column, message: message, severity: "error")]
            }
        }

        // Also try Python traceback format: `File "<string>", line N`
        let tracebackPattern = #"line (\d+)"#
        if let regex = try? NSRegularExpression(pattern: tracebackPattern),
           let match = regex.firstMatch(in: error, range: NSRange(error.startIndex..., in: error)) {
            let lineRange = match.range(at: 1)
            if let lineSwiftRange = Range(lineRange, in: error),
               let line = Int(error[lineSwiftRange]) {
                let message = errorPortion.trimmingCharacters(in: .whitespacesAndNewlines)
                return [ParsedMarker(line: line, column: nil, message: message, severity: "error")]
            }
        }

        // No line info — fallback to line 1
        let message = errorPortion.trimmingCharacters(in: .whitespacesAndNewlines)
        return [ParsedMarker(line: 1, column: nil, message: message, severity: "error")]
    }

    // MARK: - Rust

    /// Rust compilation errors from rustc stderr contain ` --> path:LINE:COL` patterns.
    /// Multiple errors/warnings can appear. Each `error[...]` or `warning[...]` block
    /// has a ` --> ` line with location info.
    /// Example:
    /// ```
    /// error[E0308]: mismatched types
    ///  --> dsp.rs:5:10
    /// ```
    private static func parseRust(_ error: String) -> [ParsedMarker] {
        var markers: [ParsedMarker] = []
        let lines = error.components(separatedBy: "\n")

        // Track current error/warning message for pairing with location
        var currentMessage: String?
        var currentSeverity = "error"

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect error or warning header lines
            if trimmed.hasPrefix("error") {
                currentSeverity = "error"
                // Extract message after `: ` (skip the error code like `error[E0308]: `)
                if let colonRange = trimmed.range(of: ": ") {
                    currentMessage = String(trimmed[colonRange.upperBound...])
                } else {
                    currentMessage = trimmed
                }
            } else if trimmed.hasPrefix("warning") {
                currentSeverity = "warning"
                if let colonRange = trimmed.range(of: ": ") {
                    currentMessage = String(trimmed[colonRange.upperBound...])
                } else {
                    currentMessage = trimmed
                }
            }

            // Detect location line: ` --> path:LINE:COL`
            let locationPattern = #"-->\s+.*?:(\d+):(\d+)"#
            if let regex = try? NSRegularExpression(pattern: locationPattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                let lineRange = match.range(at: 1)
                let colRange = match.range(at: 2)
                if let lineSwiftRange = Range(lineRange, in: trimmed),
                   let eLine = Int(trimmed[lineSwiftRange]) {
                    var column: Int?
                    if let colSwiftRange = Range(colRange, in: trimmed) {
                        column = Int(trimmed[colSwiftRange])
                    }
                    let message = currentMessage ?? "Compilation error"
                    markers.append(ParsedMarker(
                        line: eLine,
                        column: column,
                        message: message,
                        severity: currentSeverity
                    ))
                    currentMessage = nil
                }
            }
        }

        // If no locations found, fallback to line 1 with the first error message
        if markers.isEmpty {
            let message = extractFirstRustError(error)
            return [ParsedMarker(line: 1, column: nil, message: message, severity: "error")]
        }

        return markers
    }

    /// Extract the first meaningful error message from rustc output or a generic WASM error.
    private static func extractFirstRustError(_ error: String) -> String {
        // Look for first "error..." line
        for line in error.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("error") {
                return trimmed
            }
        }
        // Return entire message trimmed
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown error" : trimmed
    }
}
