//
//  FactoryWasmSidecarTests.swift
//  ConjureDSPLogicTests
//
//  Verifies the sidecar lookup contract: SHA256(source) → <dir>/<hash>.wasm.
//  Covers hit, miss, empty dir, and the cross-check against the shell-level
//  `shasum -a 256` naming used by scripts/build-factory-wasm.sh.
//

import CryptoKit
import Foundation
import Testing

@Suite("FactoryWasmSidecar")
struct FactoryWasmSidecarTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FactoryWasmTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("sha256Hex matches CryptoKit's SHA256 over UTF-8 bytes")
    func sha256MatchesExpected() {
        let source = "fn process() {}\n"
        let expected = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(FactoryWasmSidecar.sha256Hex(of: source) == expected)
    }

    @Test("Lookup hits when sidecar file exists at the hashed name")
    func hitWhenSidecarExists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = "fn process() { /* factory */ }\n"
        let hash = FactoryWasmSidecar.sha256Hex(of: source)
        let bytes = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])  // wasm magic
        try bytes.write(to: dir.appendingPathComponent("\(hash).wasm"))

        let found = FactoryWasmSidecar.wasm(forSource: source, sidecarDirectory: dir)
        #expect(found == bytes)
    }

    @Test("Lookup misses when source has been edited")
    func missWhenSourceEdited() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let factory = "fn process() { /* factory */ }\n"
        let edited = "fn process() { /* user edited */ }\n"
        let bytes = Data([0x00, 0x61, 0x73, 0x6D])
        try bytes.write(to: dir.appendingPathComponent("\(FactoryWasmSidecar.sha256Hex(of: factory)).wasm"))

        #expect(FactoryWasmSidecar.wasm(forSource: edited, sidecarDirectory: dir) == nil)
    }

    @Test("Nil sidecar directory returns nil")
    func nilDirReturnsNil() {
        #expect(FactoryWasmSidecar.wasm(forSource: "anything", sidecarDirectory: nil) == nil)
    }

    @Test("Missing sidecar file returns nil without throwing")
    func missingFileReturnsNil() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FactoryWasmSidecar.wasm(forSource: "no match", sidecarDirectory: dir) == nil)
    }

    @Test("Hash is stable across separate invocations with the same input")
    func hashIsStable() {
        let source = "pub fn compute() -> f32 { 1.0 }"
        let first = FactoryWasmSidecar.sha256Hex(of: source)
        let second = FactoryWasmSidecar.sha256Hex(of: source)
        #expect(first == second)
        #expect(first.count == 64)
        #expect(first.allSatisfy { $0.isHexDigit })
    }
}
