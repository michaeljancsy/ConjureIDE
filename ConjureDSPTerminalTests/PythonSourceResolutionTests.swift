//
//  PythonSourceResolutionTests.swift
//  ConjureDSPTerminalTests
//
//  Verifies TerminalAppServer.resolvePythonSource() correctly prefers a
//  user-installed Python language module over the bundled python-dist, and
//  falls back cleanly when either is missing.
//

import Foundation
import Testing
@testable import ConjureDSPTerminal

@Suite("Python source resolution")
struct PythonSourceResolutionTests {

    // MARK: - Fixture helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PySourceTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a minimal Python module layout under modulesRoot/python/.
    private func writeModuleFixture(
        at modulesRoot: URL,
        version: String
    ) throws {
        let moduleDir = modulesRoot.appendingPathComponent("python")
        try FileManager.default.createDirectory(
            at: moduleDir.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        // Create a dummy bin/python3 (just needs to exist).
        let binary = moduleDir.appendingPathComponent("bin/python3")
        try Data().write(to: binary)

        let manifest = InstalledLanguageModuleManifest(
            name: "python",
            version: version,
            installedAt: Date().timeIntervalSince1970,
            sha256: "deadbeef",
            installedBytes: 1024,
            entrypoints: [:]
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: moduleDir.appendingPathComponent(LanguageModuleIPC.manifestFile))
    }

    /// Writes a dummy bundled python-dist at bundledSource.
    private func writeBundledFixture(at bundledSource: URL) throws {
        try FileManager.default.createDirectory(at: bundledSource, withIntermediateDirectories: true)
    }

    // MARK: - Tests

    @Test("Prefers the language module over the bundled source when both exist")
    func prefersModuleOverBundled() throws {
        let modulesRoot = try makeTempDir()
        let bundled = try makeTempDir().appendingPathComponent("python-dist")
        defer {
            try? FileManager.default.removeItem(at: modulesRoot)
            try? FileManager.default.removeItem(at: bundled.deletingLastPathComponent())
        }

        try writeModuleFixture(at: modulesRoot, version: "3.14.3")
        try writeBundledFixture(at: bundled)

        let resolved = TerminalAppServer.resolvePythonSource(
            modulesRoot: modulesRoot,
            bundledSource: bundled,
            bundledBuildVersion: "42"
        )
        let result = try #require(resolved)
        #expect(result.url == modulesRoot.appendingPathComponent("python"))
        #expect(result.provenance == "module:3.14.3")
    }

    @Test("Falls back to bundled when no module is installed")
    func fallsBackToBundled() throws {
        let modulesRoot = try makeTempDir()  // exists but no python/ subdir
        let bundled = try makeTempDir().appendingPathComponent("python-dist")
        defer {
            try? FileManager.default.removeItem(at: modulesRoot)
            try? FileManager.default.removeItem(at: bundled.deletingLastPathComponent())
        }
        try writeBundledFixture(at: bundled)

        let resolved = TerminalAppServer.resolvePythonSource(
            modulesRoot: modulesRoot,
            bundledSource: bundled,
            bundledBuildVersion: "42"
        )
        let result = try #require(resolved)
        #expect(result.url == bundled)
        #expect(result.provenance == "bundled:42")
    }

    @Test("Module with missing bin/python3 falls back to bundled")
    func moduleWithoutBinaryFallsBack() throws {
        let modulesRoot = try makeTempDir()
        let bundled = try makeTempDir().appendingPathComponent("python-dist")
        defer {
            try? FileManager.default.removeItem(at: modulesRoot)
            try? FileManager.default.removeItem(at: bundled.deletingLastPathComponent())
        }

        // Manifest exists but no bin/python3 — mimics a half-extracted install.
        let moduleDir = modulesRoot.appendingPathComponent("python")
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        let manifest = InstalledLanguageModuleManifest(
            name: "python", version: "3.14.3", installedAt: 0,
            sha256: "x", installedBytes: 0, entrypoints: [:]
        )
        try JSONEncoder().encode(manifest)
            .write(to: moduleDir.appendingPathComponent(LanguageModuleIPC.manifestFile))
        try writeBundledFixture(at: bundled)

        let resolved = TerminalAppServer.resolvePythonSource(
            modulesRoot: modulesRoot,
            bundledSource: bundled,
            bundledBuildVersion: "42"
        )
        let result = try #require(resolved)
        #expect(result.provenance == "bundled:42")
    }

    @Test("Returns nil when neither source exists")
    func returnsNilWhenNothingAvailable() throws {
        let modulesRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: modulesRoot) }

        let resolved = TerminalAppServer.resolvePythonSource(
            modulesRoot: modulesRoot,
            bundledSource: nil,
            bundledBuildVersion: "42"
        )
        #expect(resolved == nil)
    }

    @Test("Provenance token changes when the module version changes")
    func provenanceReflectsModuleVersion() throws {
        let modulesRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: modulesRoot) }

        try writeModuleFixture(at: modulesRoot, version: "3.14.3")
        let first = try #require(TerminalAppServer.resolvePythonSource(
            modulesRoot: modulesRoot,
            bundledSource: nil,
            bundledBuildVersion: "42"
        ))

        // Rewrite the manifest with a different version.
        try FileManager.default.removeItem(
            at: modulesRoot.appendingPathComponent("python")
        )
        try writeModuleFixture(at: modulesRoot, version: "3.15.0")
        let second = try #require(TerminalAppServer.resolvePythonSource(
            modulesRoot: modulesRoot,
            bundledSource: nil,
            bundledBuildVersion: "42"
        ))

        #expect(first.provenance == "module:3.14.3")
        #expect(second.provenance == "module:3.15.0")
        #expect(first.provenance != second.provenance)
    }
}
