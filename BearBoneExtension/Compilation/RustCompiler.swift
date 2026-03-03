import Foundation

/// Compiles Rust source files to WASM using the system `rustc`.
final class RustCompiler: ScriptCompiler {
    let displayName = "Rust"

    private var cachedRustcURL: URL?

    func isAvailable() async -> Bool {
        return findRustc() != nil && isWasmTargetInstalled()
    }

    func compile(source: String) async throws -> Data {
        guard let rustc = findRustc() else {
            throw CompilationError.compilerNotFound(
                "rustc not found. Install Rust via https://rustup.rs")
        }

        guard isWasmTargetInstalled() else {
            throw CompilationError.targetNotInstalled(
                "wasm32-wasip1 target not installed. Run: rustup target add wasm32-wasip1")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bearbone-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputFile = tempDir.appendingPathComponent("dsp.rs")
        let outputFile = tempDir.appendingPathComponent("dsp.wasm")
        try source.write(to: inputFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = rustc
        process.arguments = [
            "--target", "wasm32-wasip1",
            "--edition", "2021",
            "-C", "opt-level=2",
            "--crate-type", "cdylib",
            "-o", outputFile.path,
            inputFile.path,
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            // EPERM or similar — sandboxed environment
            throw CompilationError.sandboxRestriction(
                "Rust compilation requires BearBone host app. "
                    + "Load a pre-compiled .wasm file or compile in BearBone.app."
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

    private func findRustc() -> URL? {
        if let cached = cachedRustcURL { return cached }

        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.cargo/bin/rustc",
            "/usr/local/bin/rustc",
            "/opt/homebrew/bin/rustc",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedRustcURL = URL(fileURLWithPath: path)
                return cachedRustcURL
            }
        }

        // Try which rustc with augmented PATH
        if let path = runCommand("/usr/bin/which", args: ["rustc"], extraPath: "\(home)/.cargo/bin") {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && FileManager.default.isExecutableFile(atPath: trimmed) {
                cachedRustcURL = URL(fileURLWithPath: trimmed)
                return cachedRustcURL
            }
        }

        return nil
    }

    private func isWasmTargetInstalled() -> Bool {
        guard let rustc = findRustc() else { return false }
        guard let output = runCommand(rustc.path, args: ["--print", "target-list"]) else {
            return false
        }
        return output.contains("wasm32-wasip1")
    }

    private func runCommand(
        _ path: String, args: [String], extraPath: String? = nil
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        if let extraPath = extraPath {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":" + extraPath
            process.environment = env
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
