//
//  CrateInstallerProbeTests.swift
//  ConjureDSPTerminalTests
//
//  Covers CrateInstaller.init?(appGroupURL:) probe order:
//    1. <AppGroup>/LanguageModules/rustc/  (Phase 3+ user-installed module)
//    2. <AppGroup>/rustc-dist/             (legacy bundled-copy path)
//
//  Wrong order would have Terminal's cargo reach into a stale toolchain
//  even after a fresh rustc language-module install, so this is worth
//  pinning down.
//

import Foundation
import Testing
@testable import ConjureDSPTerminal

@Suite("CrateInstaller sysroot probe order")
struct CrateInstallerProbeTests {

    private func makeTempContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateInst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Populates a sysroot skeleton under `parent` with a `bin/` that has
    /// empty (but existing) cargo + rustc files. CrateInstaller only probes
    /// for file existence, not shebang validity.
    private func seedSysroot(at parent: URL, name: String) throws -> URL {
        let root = parent.appendingPathComponent(name)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: bin.appendingPathComponent("cargo"))
        try Data().write(to: bin.appendingPathComponent("rustc"))
        return root
    }

    @Test("Init returns nil when neither candidate sysroot exists")
    func noSysrootAvailable() throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let installer = CrateInstaller(appGroupURL: container)
        #expect(installer == nil)
    }

    @Test("Prefers LanguageModules/rustc when both sysroots exist")
    func prefersLanguageModuleOverLegacy() throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let moduleRoot = try seedSysroot(
            at: container.appendingPathComponent("LanguageModules"),
            name: "rustc"
        )
        _ = try seedSysroot(at: container, name: "rustc-dist")

        let installer = try #require(CrateInstaller(appGroupURL: container))
        #expect(installer.sysrootPath == moduleRoot.path)
        #expect(installer.cargoPath == moduleRoot.appendingPathComponent("bin/cargo").path)
        #expect(installer.rustcPath == moduleRoot.appendingPathComponent("bin/rustc").path)
    }

    @Test("Falls back to legacy rustc-dist when module is absent")
    func fallsBackToLegacy() throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let legacyRoot = try seedSysroot(at: container, name: "rustc-dist")

        let installer = try #require(CrateInstaller(appGroupURL: container))
        #expect(installer.sysrootPath == legacyRoot.path)
    }

    @Test("Rejects a half-installed sysroot (cargo missing)")
    func rejectsMissingCargo() throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let bin = container
            .appendingPathComponent("LanguageModules/rustc/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Only write rustc — cargo missing
        try Data().write(to: bin.appendingPathComponent("rustc"))

        let installer = CrateInstaller(appGroupURL: container)
        #expect(installer == nil)
    }

    @Test("Rejects a half-installed sysroot (rustc missing)")
    func rejectsMissingRustc() throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        let bin = container
            .appendingPathComponent("LanguageModules/rustc/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: bin.appendingPathComponent("cargo"))
        // rustc missing

        let installer = CrateInstaller(appGroupURL: container)
        #expect(installer == nil)
    }
}
