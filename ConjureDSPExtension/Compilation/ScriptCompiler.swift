import Foundation

/// Protocol for compiling DSP source code to WASM bytes.
protocol ScriptCompiler {
    /// Compile source code to WASM bytes.
    func compile(source: String) async throws -> Data

    /// Check if the compiler toolchain is available.
    func isAvailable() async -> Bool

    /// Human-readable name for error messages.
    var displayName: String { get }
}

/// Errors that can occur during WASM compilation.
enum CompilationError: LocalizedError {
    case compilerNotFound(String)
    case targetNotInstalled(String)
    case compilationFailed(String)
    case sandboxRestriction(String)

    var errorDescription: String? {
        switch self {
        case .compilerNotFound(let msg): return msg
        case .targetNotInstalled(let msg): return msg
        case .compilationFailed(let msg): return msg
        case .sandboxRestriction(let msg): return msg
        }
    }
}
