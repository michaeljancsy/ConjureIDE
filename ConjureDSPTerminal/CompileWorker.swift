//
//  CompileWorker.swift
//  ConjureDSPTerminal
//
//  Terminal-side of the compile IPC. The AU extension can't spawn rustc
//  itself — AU sandbox rules forbid exec'ing any binary outside the
//  extension's own signed bundle. So once rustc moves to a downloadable
//  language module (Phase 3+), every compile has to be proxied through the
//  Terminal (which runs as an ordinary app, not a sandboxed extension).
//
//  Protocol (see Shared/CompileIPC.swift):
//    1. Extension writes <AppGroup>/compile-request.json with source + crate deps.
//    2. This worker picks it up on the next poll, runs rustc from the installed
//       rustc language module, writes the WASM bytes to
//       <AppGroup>/compile-output/<requestId>.wasm.
//    3. Worker writes <AppGroup>/compile-result.json. The extension polls for it.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.Terminal", category: "CompileWorker")

final class CompileWorker {
    let appGroupURL: URL
    private let outputDir: URL

    init(appGroupURL: URL) {
        self.appGroupURL = appGroupURL
        self.outputDir = appGroupURL.appendingPathComponent(CompileIPC.outputDirectory)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        log.info("CompileWorker ready — output=\(self.outputDir.path, privacy: .public)")
    }

    /// Called from the Terminal main loop every ~500ms. Handles at most one
    /// compile per tick. Deliberately synchronous within a single compile so
    /// we never run two rustc invocations in parallel (rustc is already
    /// heavy enough; real-world DSP editing doesn't need concurrency here).
    func checkForRequests() async {
        let requestURL = appGroupURL.appendingPathComponent(CompileIPC.requestFile)
        guard FileManager.default.fileExists(atPath: requestURL.path),
              let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(CompileRequest.self, from: data)
        else { return }

        // Consume the request file immediately so a slow compile doesn't get
        // re-picked-up on the next poll.
        try? FileManager.default.removeItem(at: requestURL)

        log.info("Compile \(request.requestId, privacy: .public) — language=\(request.language, privacy: .public) sourceBytes=\(request.source.count)")

        let result = runCompile(request: request)
        writeResult(result)
    }

    // MARK: - Compile

    private func runCompile(request: CompileRequest) -> CompileResult {
        guard request.language == "rust" else {
            return failure(
                request,
                message: "Unsupported compile language '\(request.language)' — only rust is wired up."
            )
        }

        guard let sysroot = locateRustSysroot() else {
            return failure(
                request,
                message: "Rust compiler not installed. Open the Languages panel and install the Rust module."
            )
        }

        let rustc = sysroot.appendingPathComponent("bin/rustc")
        guard FileManager.default.isExecutableFile(atPath: rustc.path) else {
            return failure(
                request,
                message: "rustc at \(rustc.path) is not executable — module install may be corrupted."
            )
        }

        // Stage source + destination paths in a per-request temp dir so
        // concurrent requests (shouldn't happen today but cheap to be safe)
        // don't stomp each other's inputs.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConjureDSP-Compile-\(request.requestId)")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let inputFile = workDir.appendingPathComponent("dsp.rs")
        let outputFile = outputDir.appendingPathComponent("\(request.requestId).wasm")
        try? FileManager.default.removeItem(at: outputFile)

        do {
            try request.source.write(to: inputFile, atomically: true, encoding: .utf8)
        } catch {
            return failure(request, message: "Failed to stage source: \(error.localizedDescription)")
        }

        var args: [String] = [
            "--target", "wasm32-wasip1",
            "--edition", "2021",
            "-C", "opt-level=2",
            "--crate-type", "cdylib",
            "--sysroot", sysroot.path,
            "-o", outputFile.path,
        ]
        if let rlib = request.conjuredspRlibPath,
           FileManager.default.fileExists(atPath: rlib) {
            args.append(contentsOf: ["--extern", "conjuredsp=\(rlib)"])
        }
        if let libDir = request.cratesLibPath,
           FileManager.default.fileExists(atPath: libDir) {
            args.append(contentsOf: ["-L", "dependency=\(libDir)"])
        }
        for ex in request.externs where ex.name != "conjuredsp" {
            args.append(contentsOf: ["--extern", "\(ex.name)=\(ex.path)"])
        }
        args.append(inputFile.path)

        let process = Process()
        process.executableURL = rustc
        process.arguments = args

        // rustc dlopens librustc_driver from the sibling lib/ directory. SIP
        // strips DYLD_LIBRARY_PATH from hardened-runtime children, so we
        // pass DYLD_FALLBACK_LIBRARY_PATH which is honored even for signed
        // binaries. Same trick CrateInstaller uses for cargo.
        var env = ProcessInfo.processInfo.environment
        let libPath = sysroot.appendingPathComponent("lib").path
        if let existing = env["DYLD_FALLBACK_LIBRARY_PATH"], !existing.isEmpty {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(libPath):\(existing)"
        } else {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = libPath
        }
        process.environment = env

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return failure(
                request,
                message: "Failed to launch rustc: \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            return CompileResult(
                requestId: request.requestId,
                success: false,
                wasmPath: nil,
                errorMessage: "Rust compile failed (exit \(process.terminationStatus))",
                stderr: stderr.isEmpty ? nil : stderr,
                timestamp: Date().timeIntervalSince1970
            )
        }

        guard FileManager.default.fileExists(atPath: outputFile.path) else {
            return failure(
                request,
                message: "rustc exited 0 but produced no output file at \(outputFile.path)",
                stderr: stderr
            )
        }

        log.info("Compile \(request.requestId, privacy: .public) succeeded — \(outputFile.path, privacy: .public)")
        return CompileResult(
            requestId: request.requestId,
            success: true,
            wasmPath: outputFile.path,
            errorMessage: nil,
            stderr: stderr.isEmpty ? nil : stderr,
            timestamp: Date().timeIntervalSince1970
        )
    }

    // MARK: - Helpers

    /// Probe order mirrors `CrateInstaller`:
    /// 1. Installed rustc language module (Phase 3+).
    /// 2. Legacy rustc-dist copy (pre-Phase-3 terminals).
    private func locateRustSysroot() -> URL? {
        let candidates = [
            appGroupURL.appendingPathComponent("LanguageModules/rustc"),
            appGroupURL.appendingPathComponent("rustc-dist"),
        ]
        for sysroot in candidates {
            let rustc = sysroot.appendingPathComponent("bin/rustc").path
            if FileManager.default.fileExists(atPath: rustc) {
                return sysroot
            }
        }
        return nil
    }

    private func failure(
        _ request: CompileRequest,
        message: String,
        stderr: String? = nil
    ) -> CompileResult {
        log.error("Compile \(request.requestId, privacy: .public) failed — \(message, privacy: .public)")
        return CompileResult(
            requestId: request.requestId,
            success: false,
            wasmPath: nil,
            errorMessage: message,
            stderr: stderr,
            timestamp: Date().timeIntervalSince1970
        )
    }

    private func writeResult(_ result: CompileResult) {
        let resultURL = appGroupURL.appendingPathComponent(CompileIPC.resultFile)
        do {
            let data = try JSONEncoder().encode(result)
            try data.write(to: resultURL, options: .atomic)
        } catch {
            log.error("Failed to write compile result: \(error.localizedDescription, privacy: .public)")
        }
    }
}
