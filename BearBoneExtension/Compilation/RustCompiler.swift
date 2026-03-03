import Foundation
import os

/// Compiles Rust source files to WASM.
///
/// Prefers the bundled Rust compiler (shipped inside the extension's Resources)
/// which works even in sandboxed DAW hosts. Falls back to user-installed rustc
/// for development convenience.
final class RustCompiler: ScriptCompiler {
    let displayName = "Rust"

    private var cachedRustcURL: URL?
    private var useBundledSysroot = false
    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "RustCompiler")

    func isAvailable() async -> Bool {
        return findRustc() != nil
    }

    func compile(source: String) async throws -> Data {
        guard let rustc = findRustc() else {
            log.error("compile: findRustc returned nil")
            throw CompilationError.compilerNotFound(
                "Rust compiler not found. The bundled compiler may be missing — "
                    + "run scripts/setup-rustc.sh and rebuild.")
        }
        log.info("compile: using rustc at \(rustc.path, privacy: .public), bundled=\(self.useBundledSysroot)")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bearbone-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputFile = tempDir.appendingPathComponent("dsp.rs")
        let outputFile = tempDir.appendingPathComponent("dsp.wasm")
        try source.write(to: inputFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = rustc

        var args = [
            "--target", "wasm32-wasip1",
            "--edition", "2021",
            "-C", "opt-level=2",
            "--crate-type", "cdylib",
            "-o", outputFile.path,
            inputFile.path,
        ]

        // When using bundled compiler, set explicit sysroot
        if useBundledSysroot, let sysroot = bundledSysroot() {
            args = ["--sysroot", sysroot.path] + args

            // Set DYLD_LIBRARY_PATH so librustc_driver can be found
            var env = ProcessInfo.processInfo.environment
            env["DYLD_LIBRARY_PATH"] = sysroot.appendingPathComponent("lib").path
            process.environment = env
        }

        process.arguments = args

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            let nsErr = error as NSError
            log.error("compile: Process.run() failed: domain=\(nsErr.domain, privacy: .public) code=\(nsErr.code) \(error.localizedDescription, privacy: .public)")
            throw CompilationError.sandboxRestriction(
                "Failed to run Rust compiler: \(error.localizedDescription)"
            )
        }

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr =
                String(data: stderrData, encoding: .utf8) ?? "Unknown compilation error"
            throw CompilationError.compilationFailed(stderr)
        }

        return try Data(contentsOf: outputFile)
    }

    // MARK: - Private

    /// Find the bundled rustc-dist sysroot in the extension bundle's Resources.
    private func bundledSysroot() -> URL? {
        let bundle = Bundle(for: RustCompiler.self)
        guard let path = bundle.path(forResource: "rustc-dist", ofType: nil) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// Find the bundled rustc binary.
    private func bundledRustc() -> URL? {
        guard let sysroot = bundledSysroot() else { return nil }
        let rustc = sysroot.appendingPathComponent("bin/rustc")
        if FileManager.default.fileExists(atPath: rustc.path) {
            return rustc
        }
        return nil
    }

    /// Real user home directory, bypassing sandbox container redirection.
    private var realUserHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    private func findRustc() -> URL? {
        if let cached = cachedRustcURL { return cached }

        // Prefer bundled compiler (works in sandbox)
        if let bundled = bundledRustc() {
            log.info("findRustc: using bundled compiler at \(bundled.path, privacy: .public)")
            cachedRustcURL = bundled
            useBundledSysroot = true
            return cachedRustcURL
        }

        // Fall back to user-installed rustc (development convenience)
        let home = realUserHome
        let candidates = [
            "\(home)/.cargo/bin/rustc",
            "/usr/local/bin/rustc",
            "/opt/homebrew/bin/rustc",
        ]

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                log.info("findRustc: found system rustc at \(path, privacy: .public) → \(resolved.path, privacy: .public)")
                cachedRustcURL = resolved
                useBundledSysroot = false
                return cachedRustcURL
            }
        }

        log.error("findRustc: no rustc found (home=\(home, privacy: .public))")
        return nil
    }
}
