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
    private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "RustCompiler")

    func isAvailable() async -> Bool {
        return findRustc() != nil
    }

    func compile(source: String) async throws -> Data {
        guard let rustc = findRustc() else {
            log.error("compile: findRustc returned nil")
            SentryHelper.capture("Rust compiler not found", level: .error, category: "compilation")
            throw CompilationError.compilerNotFound(
                "Rust compiler not found. The bundled compiler may be missing — "
                    + "run scripts/setup-rustc.sh and rebuild.")
        }
        log.info("compile: using rustc at \(rustc.path, privacy: .public), bundled=\(self.useBundledSysroot)")

        // Run the whole process-launch + waitUntilExit on a detached task so
        // the caller's actor (usually @MainActor via `compileAndRun`) is
        // released for the duration of the compile. Otherwise `waitUntilExit`
        // blocks whatever thread we're running on — and if that's main,
        // SwiftUI can't flush the new preset's `currentBundle` update and
        // the WKWebView's scheme handler can't serve `ui/index.html`, so the
        // custom UI stays blank until compilation finishes.
        let useBundledSysroot = self.useBundledSysroot
        let log = self.log
        return try await Task.detached {
            try Self.runCompileProcess(
                rustc: rustc,
                source: source,
                useBundledSysroot: useBundledSysroot,
                bundledSysroot: self.bundledSysroot(),
                log: log
            )
        }.value
    }

    /// Blocking process runner — everything that used to live inline in
    /// `compile` before the `Task.detached` wrapper was added. Keep this
    /// private + static so it can't accidentally capture instance state
    /// from a different thread.
    private static func runCompileProcess(
        rustc: URL,
        source: String,
        useBundledSysroot: Bool,
        bundledSysroot: URL?,
        log: Logger
    ) throws -> Data {

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conjuredsp-compile-\(UUID().uuidString)")
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

        // When using bundled compiler, set explicit sysroot and link conjuredsp rlib
        if useBundledSysroot, let sysroot = bundledSysroot {
            args = ["--sysroot", sysroot.path] + args

            // Link conjuredsp rlib if available
            let rlibPath = sysroot.appendingPathComponent("lib/libconjuredsp.rlib").path
            if FileManager.default.fileExists(atPath: rlibPath) {
                args = ["--extern", "conjuredsp=\(rlibPath)"] + args
            }

            // Set DYLD_LIBRARY_PATH so librustc_driver can be found
            var env = ProcessInfo.processInfo.environment
            env["DYLD_LIBRARY_PATH"] = sysroot.appendingPathComponent("lib").path
            process.environment = env
        } else {
            // System rustc: look for rlib in repo's rustc-dist
            if let rlibPath = Self.findRepoRlib() {
                args = ["--extern", "conjuredsp=\(rlibPath)"] + args
            }
        }

        // Link user-installed crates from crate package manager
        let userExterns = CrateInstallManager.externArgs()
        if !userExterns.isEmpty {
            let libDir = CrateInstallManager.cratesLibURL().path
            args = ["-L", "dependency=\(libDir)"] + args
            for (name, path) in userExterns where name != "conjuredsp" {
                args = ["--extern", "\(name)=\(path)"] + args
            }
            log.info("Linking \(userExterns.count) user-installed crate(s)")
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
            SentryHelper.captureError(error, category: "compilation", extra: ["rustcPath": rustc.path, "bundled": useBundledSysroot])
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
    private static var realUserHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    private var realUserHome: String { Self.realUserHome }

    /// Find the conjuredsp rlib in the repo's rustc-dist (for system rustc fallback).
    /// Walks up from the extension bundle to find the source repo's rustc-dist.
    private static func findRepoRlib() -> String? {
        // The bundle is inside DerivedData; the source repo is at SRCROOT.
        // Try common development locations relative to the real home directory.
        let home = realUserHome

        // Search for rustc-dist/lib/libconjuredsp.rlib in likely repo locations
        let searchRoots = [
            Bundle(for: RustCompiler.self).bundleURL
                .deletingLastPathComponent()  // .app or .appex parent
                .deletingLastPathComponent()
                .deletingLastPathComponent(),
        ]

        // Also try walking up from __FILE__ equivalent via bundle
        // In practice, this fallback is only used during development with system rustc
        for root in searchRoots {
            let candidate = root.appendingPathComponent("rustc-dist/lib/libconjuredsp.rlib")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }

        // Try well-known development paths
        let wellKnown = "\(home)/Code Projects/conjuredsp-application/rustc-dist/lib/libconjuredsp.rlib"
        if FileManager.default.fileExists(atPath: wellKnown) {
            return wellKnown
        }

        return nil
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
        SentryHelper.capture("No rustc found in any search path", level: .error, category: "compilation")
        return nil
    }
}
