import Foundation

enum ScriptLanguage: String {
    case python
    case rust

    /// Heuristic language detection from source content.
    /// Defaults to Python if no Rust indicators are found.
    static func detect(from source: String) -> ScriptLanguage {
        if source.contains("fn process(") || source.contains("#[no_mangle]")
            || source.contains("use conjuredsp") || source.contains("setup!()")
        {
            return .rust
        }
        return .python
    }
}
