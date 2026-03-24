import Foundation

enum ScriptLanguage: String, CaseIterable {
    case python
    case rust

    /// Heuristic language detection from source content.
    /// Defaults to Python if no Rust indicators are found.
    static func detect(from source: String) -> ScriptLanguage {
        if source.contains("fn process(") || source.contains("#[no_mangle]") {
            return .rust
        }
        return .python
    }
}
