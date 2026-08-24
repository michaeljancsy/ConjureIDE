//
//  CrateErrorMapper.swift
//  ConjureDSPExtension
//
//  Maps raw cargo error output to user-friendly error messages by detecting
//  recognizable error patterns from WebAssembly cross-compilation.
//

import Foundation

enum CrateErrorMapper {
    /// Prepends a user-friendly explanation to cargo errors when the failure is a
    /// recognizable class (e.g. build script failures during cross-compilation).
    static func userFriendlyError(_ raw: String) -> String {
        // pyo3 cross-compilation: crate uses Python bindings that can't target WASM
        if raw.contains("PYO3_CROSS_PYTHON_VERSION") || raw.contains("PYO3_CROSS_LIB_DIR") {
            return "This crate depends on pyo3 (Python bindings), which can't compile to WebAssembly. "
                + "Only pure Rust crates can be installed — for Python interop, use a Python package instead.\n\n"
                + raw
        }
        // Build script compilation failure: proc-macro or dependency resolution
        // issue with the bundled toolchain (e.g. wasm-bindgen's build script)
        if raw.contains("could not compile") && raw.contains("build script") {
            return "A dependency's build script failed to compile with the bundled Rust toolchain. "
                + "This crate may not be compatible with ConjureIDE's WebAssembly compilation.\n\n"
                + raw
        }
        // General build script failures: native/system dependencies
        if raw.contains("failed to run custom build command for") {
            return "This crate has a build script that failed during WebAssembly cross-compilation. "
                + "It likely depends on system libraries or native bindings not available in WASM. "
                + "Only pure Rust crates (no C/system dependencies) can be installed.\n\n"
                + raw
        }
        // Package not found (typo or wrong name)
        if raw.contains("no matching package found") {
            return "Crate not found on crates.io. Check the spelling — crate names use hyphens (e.g. \"my-crate\", not \"my_crate\").\n\n"
                + raw
        }
        return raw
    }
}
