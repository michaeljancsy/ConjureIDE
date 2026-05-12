//
//  PresetWasmCompiler.swift
//  ConjureDSPLogicTests
//
//  Shells out to the bundled rustc to compile a preset `process.rs` to
//  WASM bytes. Used by the pre-migration golden-hash capture and the
//  post-migration verification gate (see plans/an-ai-had-this-starry-moler.md).
//
//  Mirrors the production `RustCompiler.swift` argv shape so the bytes a
//  test produces are byte-identical to what the AU extension would produce
//  at runtime for the same source.
//

import Foundation

enum PresetWasmCompiler {

    enum Error: Swift.Error, CustomStringConvertible {
        case rustcNotFound(URL)
        case compileFailed(stderr: String, exitCode: Int32)
        case outputMissing(URL)

        var description: String {
            switch self {
            case .rustcNotFound(let url): return "Bundled rustc not found at \(url.path)"
            case .compileFailed(let stderr, let code): return "rustc exit \(code):\n\(stderr)"
            case .outputMissing(let url): return "rustc reported success but no output at \(url.path)"
            }
        }
    }

    /// Repository root, resolved via `#filePath` of this file:
    /// `<repo>/ConjureDSPLogicTests/PresetWasmCompiler.swift` → walk up one level.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ConjureDSPLogicTests/
            .deletingLastPathComponent()  // <repo>/
    }

    static var bundledRustcURL: URL {
        repoRoot.appendingPathComponent("rustc-dist/bin/rustc")
    }

    static var bundledSysrootURL: URL {
        repoRoot.appendingPathComponent("rustc-dist")
    }

    static var bundledConjuredspRlibURL: URL {
        repoRoot.appendingPathComponent("rustc-dist/lib/libconjuredsp.rlib")
    }

    /// Compile `sourceFile` (a preset's `process.rs`) to WASM bytes.
    /// Mirrors the args produced by `RustCompiler.runCompileProcess` in
    /// the production extension so test output matches runtime output.
    static func compile(sourceFile: URL) throws -> Data {
        let rustc = bundledRustcURL
        guard FileManager.default.fileExists(atPath: rustc.path) else {
            throw Error.rustcNotFound(rustc)
        }
        try rebuildRlibIfStale()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conjuredsp-golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputFile = tempDir.appendingPathComponent("preset.wasm")

        let sysroot = bundledSysrootURL
        let rlib = bundledConjuredspRlibURL

        var args = [
            "--sysroot", sysroot.path,
            "--extern", "conjuredsp=\(rlib.path)",
            "--target", "wasm32-wasip1",
            "--edition", "2024",
            "-C", "opt-level=2",
            "--crate-type", "cdylib",
            "-o", outputFile.path,
            sourceFile.path,
        ]
        // Drop the `--extern` pair if the rlib hasn't been built yet — the
        // compile will still succeed for stateless presets, then fail loudly
        // for any preset that imports `conjuredsp`. Matches RustCompiler's
        // behavior.
        if !FileManager.default.fileExists(atPath: rlib.path) {
            args.removeFirst(2)
            args.removeFirst(2)
        }

        let process = Process()
        process.executableURL = rustc
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = sysroot.appendingPathComponent("lib").path
        process.environment = env

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? "<binary>"
            throw Error.compileFailed(stderr: stderr, exitCode: process.terminationStatus)
        }

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            throw Error.outputMissing(outputFile)
        }

        return try Data(contentsOf: outputFile)
    }

    /// Rebuild `libconjuredsp.rlib` if any source in `rust/conjuredsp-rs/src/`
    /// is newer. The bundled rlib lives in `rustc-dist/` which the AU build
    /// phase rebuilds *into the appex Resources*, not the source tree — so
    /// the source-tree rlib can lag behind the in-crate sources by a long
    /// way (no Xcode build target keeps it fresh). Until that's fixed
    /// upstream, refresh-on-demand here.
    private static func rebuildRlibIfStale() throws {
        let rlib = bundledConjuredspRlibURL
        let srcDir = repoRoot.appendingPathComponent("rust/conjuredsp-rs/src")
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(at: srcDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        let rlibDate = (try? fm.attributesOfItem(atPath: rlib.path)[.modificationDate] as? Date) ?? .distantPast
        var newestSource = Date.distantPast
        for case let url as URL in enumerator where url.pathExtension == "rs" {
            if let d = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > newestSource {
                newestSource = d
            }
        }
        if newestSource <= rlibDate { return }

        let sysroot = bundledSysrootURL
        let entry = srcDir.appendingPathComponent("lib.rs")
        let process = Process()
        process.executableURL = bundledRustcURL
        process.arguments = [
            "--target", "wasm32-wasip1",
            "--edition", "2024",
            "--crate-type", "rlib",
            "--crate-name", "conjuredsp",
            "-C", "opt-level=2",
            "--sysroot", sysroot.path,
            "-o", rlib.path,
            entry.path,
        ]
        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = sysroot.appendingPathComponent("lib").path
        process.environment = env
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? "<binary>"
            throw Error.compileFailed(stderr: "rebuilding libconjuredsp.rlib:\n\(stderr)", exitCode: process.terminationStatus)
        }
    }

    /// Discover all factory Rust preset bundles in
    /// `ConjureDSPExtension/Resources/presets/`. Returns a sorted list of
    /// (bundleName, processRsURL) pairs.
    static func discoverFactoryRustPresets() throws -> [(name: String, processRs: URL)] {
        let presetsDir = repoRoot.appendingPathComponent("ConjureDSPExtension/Resources/presets")
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: presetsDir, includingPropertiesForKeys: nil)
        var results: [(String, URL)] = []
        for entry in entries where entry.pathExtension == "cdp" {
            let processRs = entry.appendingPathComponent("process.rs")
            if fm.fileExists(atPath: processRs.path) {
                results.append((entry.deletingPathExtension().lastPathComponent, processRs))
            }
        }
        results.sort { $0.0 < $1.0 }
        return results
    }
}
