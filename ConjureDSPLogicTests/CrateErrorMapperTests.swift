import Testing

struct CrateErrorMapperTests {

    @Test func pyo3CrossCompilation() {
        let raw = """
        error: PYO3_CROSS_PYTHON_VERSION or an abi3-py3* feature must be specified \
        when cross-compiling and PYO3_CROSS_LIB_DIR is not set.
        """
        let result = CrateErrorMapper.userFriendlyError(raw)
        #expect(result.hasPrefix("This crate depends on pyo3"))
        #expect(result.contains(raw))
    }

    @Test func pyo3CrossLibDir() {
        let raw = "error: PYO3_CROSS_LIB_DIR must point to a valid directory"
        let result = CrateErrorMapper.userFriendlyError(raw)
        #expect(result.hasPrefix("This crate depends on pyo3"))
    }

    @Test func buildScriptCompilationFailure() {
        let raw = """
        error: could not compile `wasm-bindgen` (build script) due to 1 previous error
        warning: build failed, waiting for other jobs to finish...
        """
        let result = CrateErrorMapper.userFriendlyError(raw)
        #expect(result.hasPrefix("A dependency's build script failed"))
        #expect(result.contains(raw))
    }

    @Test func buildScriptRuntimeFailure() {
        let raw = """
        error: failed to run custom build command for `openssl-sys v0.9.100`
        --- stderr
        run pkg_config fail: Could not run `pkg-config`
        """
        let result = CrateErrorMapper.userFriendlyError(raw)
        #expect(result.hasPrefix("This crate has a build script that failed"))
        #expect(result.contains("system libraries"))
        #expect(result.contains(raw))
    }

    @Test func packageNotFound() {
        let raw = """
        error: no matching package found
        searched package name: `gpu_fft`
        perhaps you meant:      gpu-fft
        """
        let result = CrateErrorMapper.userFriendlyError(raw)
        #expect(result.hasPrefix("Crate not found"))
        #expect(result.contains("hyphens"))
        #expect(result.contains(raw))
    }

    @Test func unknownErrorPassthrough() {
        let raw = "error[E0599]: no method named `foo` found for struct `Bar`"
        let result = CrateErrorMapper.userFriendlyError(raw)
        #expect(result == raw)
    }

    @Test func pyo3TakesPriorityOverBuildScript() {
        // pyo3 error also contains "failed to run custom build command" —
        // the pyo3-specific message should win
        let raw = """
        error: failed to run custom build command for `pyo3-ffi v0.28.3`
        --- stderr
        error: PYO3_CROSS_PYTHON_VERSION or an abi3-py3* feature must be specified
        """
        let result = CrateErrorMapper.userFriendlyError(raw)
        #expect(result.hasPrefix("This crate depends on pyo3"))
    }
}
