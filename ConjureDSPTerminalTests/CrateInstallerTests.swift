//
//  CrateInstallerTests.swift
//  ConjureDSPTerminalTests
//

import Testing
import Foundation
@testable import ConjureDSPTerminal

// MARK: - Wrapper Script Generation

struct CrateInstallerWrapperScriptTests {

    @Test func wrapperUsesDYLDFallbackLibraryPath() {
        let script = CrateInstaller.generateWrapperScript(
            sysrootPath: "/path/to/rustc-dist",
            rustcPath: "/path/to/rustc-dist/bin/rustc"
        )
        #expect(script.contains("DYLD_FALLBACK_LIBRARY_PATH"))
        #expect(!script.contains("export DYLD_LIBRARY_PATH="),
                "Must use DYLD_FALLBACK_LIBRARY_PATH, not DYLD_LIBRARY_PATH (SIP strips DYLD_LIBRARY_PATH from signed binaries)")
    }

    @Test func wrapperAppendsToExistingFallbackPath() {
        let script = CrateInstaller.generateWrapperScript(
            sysrootPath: "/sysroot",
            rustcPath: "/sysroot/bin/rustc"
        )
        #expect(script.contains("$DYLD_FALLBACK_LIBRARY_PATH"),
                "Must append to existing DYLD_FALLBACK_LIBRARY_PATH so cargo's own paths are preserved")
    }

    @Test func wrapperPointsToSysrootLib() {
        let sysroot = "/Users/test/Library/Group Containers/group.com.test/rustc-dist"
        let script = CrateInstaller.generateWrapperScript(
            sysrootPath: sysroot,
            rustcPath: "\(sysroot)/bin/rustc"
        )
        #expect(script.contains("\(sysroot)/lib"))
    }

    @Test func wrapperHandlesPathsWithSpaces() {
        let sysroot = "/Users/test/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/rustc-dist"
        let script = CrateInstaller.generateWrapperScript(
            sysrootPath: sysroot,
            rustcPath: "\(sysroot)/bin/rustc"
        )
        // The path with spaces must be quoted in the script
        #expect(script.contains("\"\(sysroot)/lib:$DYLD_FALLBACK_LIBRARY_PATH\""))
        #expect(script.contains("\"\(sysroot)/bin/rustc\""))
    }

    @Test func wrapperExecsRustcWithAllArgs() {
        let script = CrateInstaller.generateWrapperScript(
            sysrootPath: "/sysroot",
            rustcPath: "/sysroot/bin/rustc"
        )
        #expect(script.contains("exec \"/sysroot/bin/rustc\" \"$@\""))
    }

    @Test func wrapperStartsWithShebang() {
        let script = CrateInstaller.generateWrapperScript(
            sysrootPath: "/sysroot",
            rustcPath: "/sysroot/bin/rustc"
        )
        #expect(script.hasPrefix("#!/bin/bash\n"))
    }
}

// MARK: - Cargo Config Generation

struct CrateInstallerCargoConfigTests {

    @Test func cargoConfigTargetsWasmWithSysroot() {
        let config = CrateInstaller.generateCargoConfig(sysrootPath: "/sysroot")
        #expect(config.contains("[target.wasm32-wasip1]"))
        #expect(config.contains("\"--sysroot\", \"/sysroot\""))
    }

    @Test func cargoConfigDoesNotAddHostFlags() {
        let config = CrateInstaller.generateCargoConfig(sysrootPath: "/sysroot")
        #expect(!config.contains("[host]"),
                "Host compilations don't need cargo config flags — the rustc wrapper handles DYLD and rustc is signed with disable-library-validation")
        #expect(!config.contains("[target.aarch64"),
                "target.<host-triple> flags are NOT applied to host compilations by cargo")
    }

    @Test func cargoConfigSetsSysroot() {
        let config = CrateInstaller.generateCargoConfig(sysrootPath: "/path/to/sysroot")
        #expect(config.contains("\"--sysroot\", \"/path/to/sysroot\""))
    }

    @Test func cargoConfigHandlesPathsWithSpaces() {
        let sysroot = "/Users/test/Library/Group Containers/group.com.test/rustc-dist"
        let config = CrateInstaller.generateCargoConfig(sysrootPath: sysroot)
        #expect(config.contains("\"--sysroot\", \"\(sysroot)\""))
    }
}

// MARK: - Cargo.toml Generation

struct CrateInstallerCargoTomlTests {

    @Test func cargoTomlIncludesAllDependencies() {
        let toml = CrateInstaller.generateCargoToml(userCrates: [
            "dasp": "0.11",
            "num-complex": "0.4",
        ])
        #expect(toml.contains("dasp = \"0.11\""))
        #expect(toml.contains("num-complex = \"0.4\""))
    }

    @Test func cargoTomlSortsDependencies() {
        let toml = CrateInstaller.generateCargoToml(userCrates: [
            "zzz": "1.0",
            "aaa": "2.0",
            "mmm": "3.0",
        ])
        let aaaRange = toml.range(of: "aaa")!
        let mmmRange = toml.range(of: "mmm")!
        let zzzRange = toml.range(of: "zzz")!
        #expect(aaaRange.lowerBound < mmmRange.lowerBound)
        #expect(mmmRange.lowerBound < zzzRange.lowerBound)
    }

    @Test func cargoTomlSetsRlibCrateType() {
        let toml = CrateInstaller.generateCargoToml(userCrates: ["test": "1.0"])
        #expect(toml.contains("crate-type = [\"rlib\"]"))
    }

    @Test func cargoTomlEmptyDependencies() {
        let toml = CrateInstaller.generateCargoToml(userCrates: [:])
        #expect(toml.contains("[dependencies]"))
        // Should still be valid TOML with empty deps section
        #expect(toml.contains("[package]"))
    }
}

// MARK: - Rlib Filename Parsing

struct CrateInstallerRlibParsingTests {

    @Test func parseSimpleCrateName() {
        #expect(CrateInstaller.parseCrateName(from: "libfoo-abc123.rlib") == "foo")
    }

    @Test func parseCrateNameWithUnderscores() {
        #expect(CrateInstaller.parseCrateName(from: "libnum_complex-def456.rlib") == "num_complex")
    }

    @Test func parseCrateNameWithMultipleDashes() {
        // Last dash separates hash from name
        #expect(CrateInstaller.parseCrateName(from: "libmy_crate_name-789ghi.rlib") == "my_crate_name")
    }

    @Test func parseRejectsNonRlibFiles() {
        #expect(CrateInstaller.parseCrateName(from: "libfoo-abc123.dylib") == nil)
        #expect(CrateInstaller.parseCrateName(from: "foo-abc123.rlib") == nil)
        #expect(CrateInstaller.parseCrateName(from: "libfoo.rlib") == nil)  // no hash separator
    }

    @Test func parseRejectsEmptyAndMalformed() {
        #expect(CrateInstaller.parseCrateName(from: "") == nil)
        #expect(CrateInstaller.parseCrateName(from: "lib.rlib") == nil)
    }
}

// MARK: - Built-in Crate Detection

struct CrateInstallerBuiltInTests {

    @Test func detectsConjuredsp() {
        #expect(CrateInstaller.isBuiltInCrate("conjuredsp"))
        #expect(CrateInstaller.isBuiltInCrate("conjureDSP"))
        #expect(CrateInstaller.isBuiltInCrate("CONJUREDSP"))
    }

    @Test func detectsConjuredspWithSeparators() {
        #expect(CrateInstaller.isBuiltInCrate("conjure-dsp"))
        #expect(CrateInstaller.isBuiltInCrate("conjure_dsp"))
        #expect(CrateInstaller.isBuiltInCrate("Conjure-DSP"))
    }

    @Test func allowsOtherCrates() {
        #expect(!CrateInstaller.isBuiltInCrate("dasp"))
        #expect(!CrateInstaller.isBuiltInCrate("num-complex"))
        #expect(!CrateInstaller.isBuiltInCrate("conjuredsp-utils"))
    }
}

// MARK: - Std Crate Filtering

struct CrateInstallerStdCrateTests {

    @Test func stdCratesAreFiltered() {
        for name in ["std", "core", "alloc", "libc", "wasi", "compiler_builtins"] {
            #expect(CrateInstaller.stdCrateNames.contains(name), "\(name) should be a std crate")
        }
    }

    @Test func userCratesAreNotStd() {
        for name in ["dasp", "num_complex", "concrete_fft", "rustfft"] {
            #expect(!CrateInstaller.stdCrateNames.contains(name), "\(name) should NOT be a std crate")
        }
    }
}

// MARK: - Lock File Parsing

struct CrateInstallerLockFileTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeInstaller(at dir: URL) -> CrateInstaller? {
        // Create fake cargo and rustc so init succeeds
        let fm = FileManager.default
        let binDir = dir.appendingPathComponent("rustc-dist/bin")
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let cargo = binDir.appendingPathComponent("cargo")
        let rustc = binDir.appendingPathComponent("rustc")
        try? "#!/bin/sh\n".write(to: cargo, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\n".write(to: rustc, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cargo.path)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rustc.path)
        return CrateInstaller(appGroupURL: dir)
    }

    @Test func parsesSimpleLockFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let installer = makeInstaller(at: dir) else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        let lockContent = """
        [[package]]
        name = "concrete-fft"
        version = "0.4.1"

        [[package]]
        name = "num-complex"
        version = "0.4.6"
        """
        let lockFile = dir.appendingPathComponent("Cargo.lock")
        try lockContent.write(to: lockFile, atomically: true, encoding: .utf8)

        let versions = installer.parseLockFile(at: lockFile)
        #expect(versions["concrete-fft"] == "0.4.1")
        #expect(versions["num-complex"] == "0.4.6")
    }

    @Test func parsesLockFileWithSourceAndChecksum() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let installer = makeInstaller(at: dir) else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        let lockContent = """
        [[package]]
        name = "dasp"
        version = "0.11.0"
        source = "registry+https://github.com/rust-lang/crates.io-index"
        checksum = "abc123"

        [[package]]
        name = "dasp_sample"
        version = "0.11.0"
        source = "registry+https://github.com/rust-lang/crates.io-index"
        dependencies = [
            "dasp_frame",
        ]
        """
        let lockFile = dir.appendingPathComponent("Cargo.lock")
        try lockContent.write(to: lockFile, atomically: true, encoding: .utf8)

        let versions = installer.parseLockFile(at: lockFile)
        #expect(versions["dasp"] == "0.11.0")
        #expect(versions["dasp_sample"] == "0.11.0")
    }

    @Test func returnsEmptyForMissingLockFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let installer = makeInstaller(at: dir) else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        let versions = installer.parseLockFile(at: dir.appendingPathComponent("nonexistent.lock"))
        #expect(versions.isEmpty)
    }
}

// MARK: - Manifest Round-Trip

struct CrateInstallerManifestTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeInstaller(at dir: URL) -> CrateInstaller? {
        let fm = FileManager.default
        let binDir = dir.appendingPathComponent("rustc-dist/bin")
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let cargo = binDir.appendingPathComponent("cargo")
        let rustc = binDir.appendingPathComponent("rustc")
        try? "#!/bin/sh\n".write(to: cargo, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\n".write(to: rustc, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cargo.path)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rustc.path)
        return CrateInstaller(appGroupURL: dir)
    }

    @Test func manifestRoundTrip() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let installer = makeInstaller(at: dir) else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        let manifest = CrateInstaller.CrateManifest(
            version: 1,
            rustVersion: "1.93.1",
            crates: [
                "dasp": .init(version: "0.11.0", rlib: "libdasp-abc123.rlib", userRequested: true),
                "num-complex": .init(version: "0.4.6", rlib: "libnum_complex-def456.rlib", userRequested: false),
            ],
            manifestHash: "test-hash"
        )

        installer.writeManifest(manifest)
        let loaded = installer.readManifest()
        #expect(loaded != nil)
        #expect(loaded?.version == 1)
        #expect(loaded?.rustVersion == "1.93.1")
        #expect(loaded?.crates.count == 2)
        #expect(loaded?.crates["dasp"]?.version == "0.11.0")
        #expect(loaded?.crates["dasp"]?.userRequested == true)
        #expect(loaded?.crates["num-complex"]?.userRequested == false)
        #expect(loaded?.manifestHash == "test-hash")
    }

    @Test func readExistingUserCratesFiltersNonUserRequested() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let installer = makeInstaller(at: dir) else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        let manifest = CrateInstaller.CrateManifest(
            version: 1,
            rustVersion: "1.93.1",
            crates: [
                "dasp": .init(version: "0.11.0", rlib: "libdasp-abc.rlib", userRequested: true),
                "dasp-sample": .init(version: "0.11.0", rlib: "libdasp_sample-def.rlib", userRequested: false),
                "concrete-fft": .init(version: "0.4.1", rlib: "libconcrete_fft-ghi.rlib", userRequested: true),
            ],
            manifestHash: "hash"
        )
        installer.writeManifest(manifest)

        let userCrates = installer.readExistingUserCrates()
        #expect(userCrates.count == 2)
        #expect(userCrates["dasp"] == "0.11.0")
        #expect(userCrates["concrete-fft"] == "0.4.1")
        #expect(userCrates["dasp-sample"] == nil, "Transitive deps should be excluded")
    }

    @Test func readManifestReturnsNilWhenMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let installer = makeInstaller(at: dir) else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        #expect(installer.readManifest() == nil)
    }
}

// MARK: - Manifest Hash

struct CrateInstallerHashTests {

    private func makeInstaller() -> CrateInstaller? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateInstallerTest-\(UUID().uuidString)")
        let fm = FileManager.default
        let binDir = dir.appendingPathComponent("rustc-dist/bin")
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try? "#!/bin/sh\n".write(to: binDir.appendingPathComponent("cargo"), atomically: true, encoding: .utf8)
        try? "#!/bin/sh\n".write(to: binDir.appendingPathComponent("rustc"), atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binDir.appendingPathComponent("cargo").path)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binDir.appendingPathComponent("rustc").path)
        return CrateInstaller(appGroupURL: dir)
    }

    @Test func hashIsDeterministic() throws {
        guard let installer = makeInstaller() else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        let crates = ["dasp": "0.11", "num-complex": "0.4"]
        let hash1 = installer.computeManifestHash(crates)
        let hash2 = installer.computeManifestHash(crates)
        #expect(hash1 == hash2)
    }

    @Test func hashChangesWithDifferentVersions() throws {
        guard let installer = makeInstaller() else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        let hash1 = installer.computeManifestHash(["dasp": "0.11"])
        let hash2 = installer.computeManifestHash(["dasp": "0.12"])
        #expect(hash1 != hash2)
    }

    @Test func hashChangesWithDifferentCrates() throws {
        guard let installer = makeInstaller() else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        let hash1 = installer.computeManifestHash(["dasp": "0.11"])
        let hash2 = installer.computeManifestHash(["num-complex": "0.11"])
        #expect(hash1 != hash2)
    }

    @Test func emptyHashIsConsistent() throws {
        guard let installer = makeInstaller() else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        let hash = installer.computeManifestHash([:])
        #expect(!hash.isEmpty)
        #expect(hash == installer.computeManifestHash([:]))
    }
}

// MARK: - Rustc Entitlement Verification

struct CrateInstallerEntitlementTests {

    /// Verify the App Group container's rustc has disable-library-validation.
    /// Without this entitlement, rustc crashes (SIGABRT) when trying to dlopen
    /// proc-macro dylibs compiled by cargo, because macOS hardened runtime
    /// library validation blocks loading unsigned code.
    @Test func rustcHasDisableLibraryValidation() throws {
        let sysroot = AppGroupContainer.url.appendingPathComponent("rustc-dist")
        let rustc = sysroot.appendingPathComponent("bin/rustc")
        guard FileManager.default.fileExists(atPath: rustc.path) else {
            Issue.record("rustc not found at \(rustc.path) — run a build first to provision it")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", "-", "--xml", rustc.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        #expect(output.contains("disable-library-validation"),
                "rustc must be signed with com.apple.security.cs.disable-library-validation to load proc-macro dylibs")
    }
}

// MARK: - Proc-Macro Integration Test

struct CrateInstallerProcMacroIntegrationTests {

    /// Builds a crate project to wasm32-wasip1 using the bundled toolchain,
    /// matching exactly what CrateInstaller does at runtime.
    private func buildCrate(
        cargoToml: String,
        sourceCode: String,
        expectedRlib: String
    ) async throws {
        let containerURL = AppGroupContainer.url
        let sysroot = containerURL.appendingPathComponent("rustc-dist")
        let cargo = sysroot.appendingPathComponent("bin/cargo")
        let rustc = sysroot.appendingPathComponent("bin/rustc")

        guard FileManager.default.fileExists(atPath: cargo.path),
              FileManager.default.fileExists(atPath: rustc.path) else {
            Issue.record("Bundled toolchain not provisioned — run a build first")
            return
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("crate-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tempDir.appendingPathComponent(".cargo"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        try cargoToml.write(to: tempDir.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
        try sourceCode.write(to: tempDir.appendingPathComponent("src/lib.rs"), atomically: true, encoding: .utf8)

        let cargoConfig = CrateInstaller.generateCargoConfig(sysrootPath: sysroot.path)
        try cargoConfig.write(
            to: tempDir.appendingPathComponent(".cargo/config.toml"),
            atomically: true, encoding: .utf8
        )

        let wrapperScript = CrateInstaller.generateWrapperScript(
            sysrootPath: sysroot.path, rustcPath: rustc.path
        )
        let wrapperURL = tempDir.appendingPathComponent("rustc-wrapper.sh")
        try wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)

        let cargoHome = containerURL.appendingPathComponent("cargo-home").path
        try fm.createDirectory(atPath: cargoHome, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cargo.path)
        process.arguments = [
            "build", "--release", "--target", "wasm32-wasip1",
            "--manifest-path", tempDir.appendingPathComponent("Cargo.toml").path,
        ]
        process.environment = [
            "CARGO_HOME": cargoHome,
            "RUSTC": wrapperURL.path,
            "RUSTUP_TOOLCHAIN": "none",
            "DYLD_LIBRARY_PATH": "\(sysroot.path)/lib",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        try process.run()
        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        #expect(process.terminationStatus == 0,
                "cargo build failed (exit \(process.terminationStatus)). stderr:\n\(stderr)")

        let depsDir = tempDir.appendingPathComponent("target/wasm32-wasip1/release/deps")
        let depsContents = (try? fm.contentsOfDirectory(atPath: depsDir.path)) ?? []
        let matchingRlibs = depsContents.filter { $0.contains(expectedRlib) && $0.hasSuffix(".rlib") }
        #expect(!matchingRlibs.isEmpty, "\(expectedRlib) rlib should exist in deps after successful build")
    }

    /// Builds serde with derive feature — exercises proc-macro2, syn, quote,
    /// and serde_derive (the most common proc-macro stack in Rust).
    @Test(.timeLimit(.minutes(5)))
    func buildSerdeDerive() async throws {
        try await buildCrate(
            cargoToml: """
            [package]
            name = "serde-test"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            serde = { version = "1", features = ["derive"] }

            [lib]
            crate-type = ["rlib"]

            [profile.release]
            opt-level = 2
            """,
            sourceCode: """
            use serde::{Serialize, Deserialize};

            #[derive(Serialize, Deserialize)]
            pub struct TestStruct {
                pub value: f32,
            }
            """,
            expectedRlib: "serde"
        )
    }

    /// Builds concrete-fft — the crate that originally failed due to proc-macro
    /// loading. Its dependency chain includes build scripts (autocfg, libm,
    /// num-traits) that exercise host-target compilation during cross-compilation.
    @Test(.timeLimit(.minutes(5)))
    func buildConcreteFft() async throws {
        try await buildCrate(
            cargoToml: """
            [package]
            name = "fft-test"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            concrete-fft = "0.4"

            [lib]
            crate-type = ["rlib"]

            [profile.release]
            opt-level = 2
            """,
            sourceCode: "// uses concrete-fft as a dependency\n",
            expectedRlib: "concrete_fft"
        )
    }
}

// MARK: - Request Flow (with fake cargo)

struct CrateInstallerRequestFlowTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeInstaller(at dir: URL) -> CrateInstaller? {
        let fm = FileManager.default
        let binDir = dir.appendingPathComponent("rustc-dist/bin")
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let cargo = binDir.appendingPathComponent("cargo")
        let rustc = binDir.appendingPathComponent("rustc")
        try? "#!/bin/sh\n".write(to: cargo, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\n".write(to: rustc, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cargo.path)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rustc.path)
        return CrateInstaller(appGroupURL: dir)
    }

    @Test func rejectsConjuredspInstall() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let installer = makeInstaller(at: dir) else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        // Write an install request for the built-in crate
        let request = CrateInstaller.InstallRequest(
            requestId: "test-reject",
            crates: [CrateInstaller.CrateSpec(name: "conjuredsp", version: "1.0")],
            timestamp: Date().timeIntervalSince1970
        )
        let requestData = try JSONEncoder().encode(request)
        try requestData.write(
            to: dir.appendingPathComponent(CrateInstaller.installRequestFile))

        await installer.checkForRequests()

        // Should get a failure result
        let resultURL = dir.appendingPathComponent(CrateInstaller.installResultFile)
        #expect(FileManager.default.fileExists(atPath: resultURL.path))
        let resultData = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(CrateInstaller.InstallResult.self, from: resultData)
        #expect(result.success == false)
        #expect(result.error?.contains("built-in") == true)
    }

    @Test func rejectsConjureDSPWithHyphens() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let installer = makeInstaller(at: dir) else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        let request = CrateInstaller.InstallRequest(
            requestId: "test-reject-hyphen",
            crates: [CrateInstaller.CrateSpec(name: "conjure-dsp", version: "1.0")],
            timestamp: Date().timeIntervalSince1970
        )
        let requestData = try JSONEncoder().encode(request)
        try requestData.write(
            to: dir.appendingPathComponent(CrateInstaller.installRequestFile))

        await installer.checkForRequests()

        let resultURL = dir.appendingPathComponent(CrateInstaller.installResultFile)
        let resultData = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(CrateInstaller.InstallResult.self, from: resultData)
        #expect(result.success == false)
        #expect(result.error?.contains("built-in") == true)
    }

    @Test func requestFileRemovedAfterProcessing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let installer = makeInstaller(at: dir) else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        let request = CrateInstaller.InstallRequest(
            requestId: "test-cleanup",
            crates: [CrateInstaller.CrateSpec(name: "conjuredsp", version: "1.0")],
            timestamp: Date().timeIntervalSince1970
        )
        let requestURL = dir.appendingPathComponent(CrateInstaller.installRequestFile)
        try JSONEncoder().encode(request).write(to: requestURL)

        #expect(FileManager.default.fileExists(atPath: requestURL.path))
        await installer.checkForRequests()
        #expect(!FileManager.default.fileExists(atPath: requestURL.path),
                "Request file should be deleted after processing")
    }

    @Test func uninstallClearsManifestWhenEmpty() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let installer = makeInstaller(at: dir) else {
            Issue.record("Failed to create CrateInstaller")
            return
        }

        // Pre-populate manifest with one user crate
        let manifest = CrateInstaller.CrateManifest(
            version: 1,
            rustVersion: "1.93.1",
            crates: [
                "dasp": .init(version: "0.11.0", rlib: "libdasp-abc.rlib", userRequested: true),
            ],
            manifestHash: "hash"
        )
        installer.writeManifest(manifest)

        // Create the rlib dir
        let rlibDir = dir.appendingPathComponent(CrateInstaller.rlibDir)
        try FileManager.default.createDirectory(at: rlibDir, withIntermediateDirectories: true)

        // Write uninstall request
        let request = CrateInstaller.UninstallRequest(
            requestId: "test-uninstall",
            crates: ["dasp"],
            timestamp: Date().timeIntervalSince1970
        )
        try JSONEncoder().encode(request).write(
            to: dir.appendingPathComponent(CrateInstaller.uninstallRequestFile))

        await installer.checkForRequests()

        // Check result
        let resultURL = dir.appendingPathComponent(CrateInstaller.installResultFile)
        let resultData = try Data(contentsOf: resultURL)
        let result = try JSONDecoder().decode(CrateInstaller.InstallResult.self, from: resultData)
        #expect(result.success == true)

        // Manifest should exist but have empty crates
        let updatedManifest = installer.readManifest()
        #expect(updatedManifest != nil)
        #expect(updatedManifest?.crates.isEmpty == true)
    }

    @Test func initFailsWithoutCargo() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateInstallerTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let installer = CrateInstaller(appGroupURL: dir)
        #expect(installer == nil, "Should return nil when cargo is not found")
    }

    @Test func initFailsWithoutRustc() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateInstallerTest-\(UUID().uuidString)")
        let binDir = dir.appendingPathComponent("rustc-dist/bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Only create cargo, not rustc
        try "#!/bin/sh\n".write(
            to: binDir.appendingPathComponent("cargo"), atomically: true, encoding: .utf8)

        let installer = CrateInstaller(appGroupURL: dir)
        #expect(installer == nil, "Should return nil when rustc is not found")
    }
}
