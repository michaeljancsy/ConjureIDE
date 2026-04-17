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
    /// Overrides `useBundledSysroot` when set. Points at the installed rustc
    /// language module's root (the same layout as rustc-dist).
    private var activeModuleSysroot: URL?
    private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "RustCompiler")

    func isAvailable() async -> Bool {
        return findRustc() != nil
    }

    func compile(source: String) async throws -> Data {
        // If rustc only lives in the installed language module, the AU
        // extension sandbox forbids exec'ing it directly — we have to
        // proxy the compile through ConjureDSPTerminal (unsandboxed).
        // Bundled rustc (Debug builds + legacy) still uses the in-process
        // fast path, which is also what runs in the host app (no AU sandbox).
        if bundledRustc() == nil, moduleRustc() != nil {
            return try await compileViaTerminal(source: source)
        }

        guard let rustc = findRustc() else {
            log.error("compile: findRustc returned nil")
            SentryHelper.capture("Rust compiler not found", level: .error, category: "compilation")
            if bundledRustc() == nil {
                throw CompilationError.rustcModuleRequired(
                    "This Rust preset needs the Rust compiler (≈193 MB). "
                        + "Open the Languages panel and install the Rust module to run it.")
            }
            throw CompilationError.compilerNotFound(
                "Rust compiler not found. The bundled compiler may be missing — "
                    + "run scripts/setup-rustc.sh and rebuild.")
        }
        log.info("compile: using rustc at \(rustc.path, privacy: .public), bundled=\(self.useBundledSysroot)")

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

        // Resolve the sysroot to thread through rustc:
        // 1. Installed language module (<AppGroup>/LanguageModules/rustc/)
        // 2. Bundled rustc-dist inside the extension .appex (legacy, pre-Phase 3)
        // 3. System rustc (fall-through — no explicit sysroot, let rustc find its own)
        let resolvedSysroot: URL? = activeModuleSysroot ?? (useBundledSysroot ? bundledSysroot() : nil)
        if let sysroot = resolvedSysroot {
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
            if let rlibPath = findRepoRlib() {
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

    /// Find the installed rustc language module (if the user has downloaded it
    /// via the Language Modules panel). Layout mirrors the bundled rustc-dist:
    /// `<AppGroup>/LanguageModules/rustc/{bin,lib}/...`.
    private func moduleSysroot() -> URL? {
        let dir = LanguageModuleManager.moduleDirectory(for: "rustc")
        let rustc = dir.appendingPathComponent("bin/rustc")
        return FileManager.default.fileExists(atPath: rustc.path) ? dir : nil
    }

    private func moduleRustc() -> URL? {
        guard let sysroot = moduleSysroot() else { return nil }
        return sysroot.appendingPathComponent("bin/rustc")
    }

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

    /// Find the conjuredsp rlib in the repo's rustc-dist (for system rustc fallback).
    /// Walks up from the extension bundle to find the source repo's rustc-dist.
    private func findRepoRlib() -> String? {
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

        // 1) Prefer an installed rustc language module. Once the bundled
        // rustc-dist is stripped from the app (Phase 3 final step), this is
        // the only source of a sandbox-safe rustc for user-authored Rust.
        if let moduleRustc = moduleRustc(), let moduleRoot = moduleSysroot() {
            log.info("findRustc: using language-module compiler at \(moduleRustc.path, privacy: .public)")
            cachedRustcURL = moduleRustc
            activeModuleSysroot = moduleRoot
            useBundledSysroot = false
            return cachedRustcURL
        }

        // 2) Fall back to the bundled compiler (works in sandbox)
        if let bundled = bundledRustc() {
            log.info("findRustc: using bundled compiler at \(bundled.path, privacy: .public)")
            cachedRustcURL = bundled
            useBundledSysroot = true
            activeModuleSysroot = nil
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

    // MARK: - IPC compile path

    /// Proxy a compile through ConjureDSPTerminal's CompileWorker. Used
    /// whenever the only available rustc is the installed language module
    /// — the AU sandbox blocks Process.run() on binaries outside the
    /// extension's own signed bundle, so we can't exec it here.
    private func compileViaTerminal(source: String) async throws -> Data {
        let container = LanguageModuleManager.moduleDirectory(for: "rustc")
            .deletingLastPathComponent() // .../LanguageModules
            .deletingLastPathComponent() // App Group root

        let requestId = UUID().uuidString
        let moduleSysroot = LanguageModuleManager.moduleDirectory(for: "rustc")
        let rlibPath = moduleSysroot.appendingPathComponent("lib/libconjuredsp.rlib").path
        let userExterns = CrateInstallManager.externArgs()
        let externs: [CompileExtern] = userExterns
            .filter { $0.name != "conjuredsp" }
            .map { CompileExtern(name: $0.name, path: $0.path) }
        let cratesLibPath = userExterns.isEmpty ? nil : CrateInstallManager.cratesLibURL().path

        let request = CompileRequest(
            requestId: requestId,
            language: "rust",
            source: source,
            conjuredspRlibPath: FileManager.default.fileExists(atPath: rlibPath) ? rlibPath : nil,
            cratesLibPath: cratesLibPath,
            externs: externs,
            timestamp: Date().timeIntervalSince1970
        )

        let requestURL = container.appendingPathComponent(CompileIPC.requestFile)
        let resultURL = container.appendingPathComponent(CompileIPC.resultFile)
        // Clear any stale result from a prior request — our polling loop
        // below matches on requestId, but a leftover file with a different
        // ID would just add noise.
        try? FileManager.default.removeItem(at: resultURL)

        do {
            let data = try JSONEncoder().encode(request)
            try data.write(to: requestURL, options: .atomic)
        } catch {
            throw CompilationError.compilationFailed(
                "Failed to queue compile for Terminal: \(error.localizedDescription)"
            )
        }

        log.info("compile: queued via Terminal — requestId=\(requestId, privacy: .public)")

        // Poll for result. Terminal's watch loop ticks ~every 500 ms, so
        // 200 ms polling gives snappy pickup without burning CPU.
        let deadline = Date().addingTimeInterval(CompileIPC.pollTimeoutSeconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))

            guard FileManager.default.fileExists(atPath: resultURL.path),
                  let data = try? Data(contentsOf: resultURL),
                  let result = try? JSONDecoder().decode(CompileResult.self, from: data),
                  result.requestId == requestId
            else { continue }

            try? FileManager.default.removeItem(at: resultURL)

            if !result.success {
                let stderr = result.stderr ?? ""
                let detail = result.errorMessage ?? "Unknown error"
                if stderr.isEmpty {
                    throw CompilationError.compilationFailed(detail)
                } else {
                    throw CompilationError.compilationFailed("\(detail)\n\n\(stderr)")
                }
            }

            guard let wasmPath = result.wasmPath else {
                throw CompilationError.compilationFailed(
                    "Compile succeeded but Terminal returned no WASM path."
                )
            }

            let wasmURL = URL(fileURLWithPath: wasmPath)
            let wasm: Data
            do {
                wasm = try Data(contentsOf: wasmURL)
            } catch {
                throw CompilationError.compilationFailed(
                    "Compile succeeded but WASM file is unreadable: \(error.localizedDescription)"
                )
            }
            try? FileManager.default.removeItem(at: wasmURL)
            return wasm
        }

        // Timed out — clean up so Terminal doesn't process the request after
        // we've already bailed.
        try? FileManager.default.removeItem(at: requestURL)
        throw CompilationError.compilationFailed(
            "Compile timed out after \(Int(CompileIPC.pollTimeoutSeconds))s. Is ConjureDSP Terminal running?"
        )
    }
}
