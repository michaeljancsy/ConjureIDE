//
//  CompileWorkerTests.swift
//  ConjureDSPTerminalTests
//
//  End-to-end IPC roundtrip for the compile-via-Terminal path. Validates
//  that the worker picks up a request, runs rustc from the installed
//  language module, and writes back a result file with WASM bytes the
//  extension can read.
//

import Foundation
import Testing
@testable import ConjureDSPTerminal

@Suite("CompileWorker IPC roundtrip")
struct CompileWorkerTests {

    private func makeTempContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompileW-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Use the real bundled rustc-dist as the toolchain. This keeps the test
    /// self-contained (no module install required) while still exercising the
    /// full request → exec → result flow the AU extension relies on.
    private func linkRustcDistIntoContainer(_ container: URL) throws -> URL? {
        let repoRustc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConjureDSPTerminalTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("rustc-dist")
        guard FileManager.default.fileExists(atPath: repoRustc.appendingPathComponent("bin/rustc").path) else {
            return nil
        }
        let dst = container.appendingPathComponent("rustc-dist")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: repoRustc)
        return dst
    }

    @Test("Missing rustc → writes success=false with an install-required hint")
    func noRustcAvailable() async throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let worker = CompileWorker(appGroupURL: container)
        let request = CompileRequest(
            requestId: "req-none",
            language: "rust",
            source: "fn main() {}",
            conjuredspRlibPath: nil,
            cratesLibPath: nil,
            externs: [],
            timestamp: Date().timeIntervalSince1970
        )
        try JSONEncoder().encode(request).write(
            to: container.appendingPathComponent(CompileIPC.requestFile),
            options: .atomic
        )

        await worker.checkForRequests()

        let resultURL = container.appendingPathComponent(CompileIPC.resultFile)
        let data = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(CompileResult.self, from: data)
        #expect(result.requestId == "req-none")
        #expect(result.success == false)
        #expect((result.errorMessage ?? "").lowercased().contains("rust"))
    }

    @Test("Unsupported language → success=false")
    func unsupportedLanguage() async throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let worker = CompileWorker(appGroupURL: container)
        let request = CompileRequest(
            requestId: "req-lua",
            language: "lua",
            source: "function process() end",
            conjuredspRlibPath: nil,
            cratesLibPath: nil,
            externs: [],
            timestamp: Date().timeIntervalSince1970
        )
        try JSONEncoder().encode(request).write(
            to: container.appendingPathComponent(CompileIPC.requestFile),
            options: .atomic
        )

        await worker.checkForRequests()
        let data = try Data(contentsOf: container.appendingPathComponent(CompileIPC.resultFile))
        let result = try JSONDecoder().decode(CompileResult.self, from: data)
        #expect(result.success == false)
        #expect((result.errorMessage ?? "").lowercased().contains("language"))
    }

    @Test("Request file is consumed even on failure")
    func requestFileConsumed() async throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let worker = CompileWorker(appGroupURL: container)
        let request = CompileRequest(
            requestId: "req-consume",
            language: "rust",
            source: "fn main() {}",
            conjuredspRlibPath: nil,
            cratesLibPath: nil,
            externs: [],
            timestamp: Date().timeIntervalSince1970
        )
        let requestURL = container.appendingPathComponent(CompileIPC.requestFile)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)

        await worker.checkForRequests()
        #expect(!FileManager.default.fileExists(atPath: requestURL.path))
    }

    @Test("Full roundtrip compiles source to WASM (uses repo rustc-dist)")
    func successfulRoundtrip() async throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        guard try linkRustcDistIntoContainer(container) != nil else {
            // Running on a machine without rustc-dist set up — skip the
            // slow exec test. The worker failure-mode tests above still
            // cover the IPC contract.
            return
        }

        let worker = CompileWorker(appGroupURL: container)
        // Smallest meaningful Rust source that produces a valid
        // wasm32-wasip1 cdylib (no imports, just one exported function).
        let source = """
        #[unsafe(no_mangle)]
        pub extern \"C\" fn process() -> i32 { 42 }
        """
        let request = CompileRequest(
            requestId: "req-ok",
            language: "rust",
            source: source,
            conjuredspRlibPath: nil,
            cratesLibPath: nil,
            externs: [],
            timestamp: Date().timeIntervalSince1970
        )
        try JSONEncoder().encode(request).write(
            to: container.appendingPathComponent(CompileIPC.requestFile),
            options: .atomic
        )

        await worker.checkForRequests()
        let data = try Data(contentsOf: container.appendingPathComponent(CompileIPC.resultFile))
        let result = try JSONDecoder().decode(CompileResult.self, from: data)
        if !result.success {
            Issue.record("Compile failed: \(result.errorMessage ?? "??") — \(result.stderr ?? "no stderr")")
            return
        }
        let wasmPath = try #require(result.wasmPath)
        let wasm = try Data(contentsOf: URL(fileURLWithPath: wasmPath))
        #expect(wasm.count > 0)
        // WASM magic: 0x00 0x61 0x73 0x6D ("\0asm")
        #expect(wasm.prefix(4) == Data([0x00, 0x61, 0x73, 0x6D]))
    }
}
