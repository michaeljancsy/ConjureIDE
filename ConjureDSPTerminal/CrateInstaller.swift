//
//  CrateInstaller.swift
//  ConjureDSPTerminal
//
//  Watches for Rust crate install/uninstall requests in the App Group container
//  and executes them using cargo + the bundled Rust toolchain. Compiles crates
//  to wasm32-wasip1 rlibs that the AU extension's RustCompiler can link.
//

import Foundation
import CryptoKit
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.Terminal", category: "CrateInstaller")

final class CrateInstaller {
    let appGroupURL: URL
    let cargoPath: String
    let rustcPath: String
    let sysrootPath: String

    static let installRequestFile = "crate-install-request.json"
    static let uninstallRequestFile = "crate-uninstall-request.json"
    static let installResultFile = "crate-install-result.json"
    static let buildProgressFile = "crate-build-progress.txt"
    static let manifestFile = "RustCrates/manifest.json"
    static let rlibDir = "RustCrates/lib"

    // MARK: - Request/Result models (must match CrateInstallManager in the extension)

    struct CrateSpec: Codable {
        let name: String
        let version: String
    }

    struct InstallRequest: Codable {
        let requestId: String
        let crates: [CrateSpec]
        let timestamp: Double
    }

    struct UninstallRequest: Codable {
        let requestId: String
        let crates: [String]
        let timestamp: Double
    }

    struct InstallResult: Codable {
        let requestId: String
        let success: Bool
        let crates: [String]
        let error: String?
        let timestamp: Double
    }

    struct CrateManifest: Codable {
        let version: Int
        let rustVersion: String
        var crates: [String: CrateEntry]
        var manifestHash: String

        struct CrateEntry: Codable {
            let version: String
            let rlib: String
            let userRequested: Bool
        }
    }

    // MARK: - Init

    init?(appGroupURL: URL) {
        self.appGroupURL = appGroupURL

        // Look for rustc-dist in App Group container (provisioned on startup)
        let sysroot = appGroupURL.appendingPathComponent("rustc-dist")
        let cargo = sysroot.appendingPathComponent("bin/cargo").path
        let rustc = sysroot.appendingPathComponent("bin/rustc").path

        guard FileManager.default.fileExists(atPath: cargo) else {
            log.error("cargo not found at \(cargo, privacy: .public)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: rustc) else {
            log.error("rustc not found at \(rustc, privacy: .public)")
            return nil
        }

        self.cargoPath = cargo
        self.rustcPath = rustc
        self.sysrootPath = sysroot.path
        log.info("CrateInstaller ready — cargo=\(cargo, privacy: .public)")
    }

    // MARK: - Check for requests

    func checkForRequests() async {
        await checkForInstallRequest()
        await checkForUninstallRequest()
    }

    private func checkForInstallRequest() async {
        let requestURL = appGroupURL.appendingPathComponent(Self.installRequestFile)
        guard FileManager.default.fileExists(atPath: requestURL.path),
              let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(InstallRequest.self, from: data)
        else { return }

        try? FileManager.default.removeItem(at: requestURL)

        let names = request.crates.map(\.name).joined(separator: ", ")
        log.info("Processing crate install request: \(names, privacy: .public)")

        do {
            try await installCrates(request.crates)
            writeResult(InstallResult(
                requestId: request.requestId,
                success: true,
                crates: request.crates.map(\.name),
                error: nil,
                timestamp: Date().timeIntervalSince1970
            ))
            log.info("Crate install succeeded: \(names, privacy: .public)")
        } catch {
            writeResult(InstallResult(
                requestId: request.requestId,
                success: false,
                crates: request.crates.map(\.name),
                error: error.localizedDescription,
                timestamp: Date().timeIntervalSince1970
            ))
            log.error("Crate install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func checkForUninstallRequest() async {
        let requestURL = appGroupURL.appendingPathComponent(Self.uninstallRequestFile)
        guard FileManager.default.fileExists(atPath: requestURL.path),
              let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(UninstallRequest.self, from: data)
        else { return }

        try? FileManager.default.removeItem(at: requestURL)

        let names = request.crates.joined(separator: ", ")
        log.info("Processing crate uninstall request: \(names, privacy: .public)")

        do {
            try await uninstallCrates(request.crates)
            writeResult(InstallResult(
                requestId: request.requestId,
                success: true,
                crates: request.crates,
                error: nil,
                timestamp: Date().timeIntervalSince1970
            ))
            log.info("Crate uninstall succeeded: \(names, privacy: .public)")
        } catch {
            writeResult(InstallResult(
                requestId: request.requestId,
                success: false,
                crates: request.crates,
                error: error.localizedDescription,
                timestamp: Date().timeIntervalSince1970
            ))
            log.error("Crate uninstall failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Install

    private func installCrates(_ newCrates: [CrateSpec]) async throws {
        // Reject built-in crate names to avoid conflicts with the bundled rlib
        for crate in newCrates {
            if crate.name.lowercased().replacingOccurrences(of: "-", with: "_") == "conjuredsp" {
                throw CrateInstallerError.buildFailed("conjuredsp is a built-in crate and cannot be installed as a dependency")
            }
        }

        // Merge new crates with existing user-requested crates.
        // Normalize names: Cargo treats hyphens and underscores as equivalent,
        // but we use underscores consistently (matching rlib filenames).
        var allCrates = readExistingUserCrates()
        for crate in newCrates {
            let normalized = crate.name.replacingOccurrences(of: "-", with: "_")
            allCrates[normalized] = crate.version
        }

        try await rebuildAllCrates(allCrates)
    }

    // MARK: - Uninstall

    private func uninstallCrates(_ crateNames: [String]) async throws {
        var allCrates = readExistingUserCrates()
        for name in crateNames {
            // Normalize to underscores to match manifest keys
            let normalized = name.replacingOccurrences(of: "-", with: "_")
            allCrates.removeValue(forKey: normalized)
        }

        if allCrates.isEmpty {
            // No crates left — just clear everything
            let rlibURL = appGroupURL.appendingPathComponent(Self.rlibDir)
            try? FileManager.default.removeItem(at: rlibURL)
            try? FileManager.default.createDirectory(at: rlibURL, withIntermediateDirectories: true)
            writeManifest(CrateManifest(
                version: 1,
                rustVersion: rustVersion(),
                crates: [:],
                manifestHash: computeManifestHash([:])
            ))
        } else {
            try await rebuildAllCrates(allCrates)
        }
    }

    // MARK: - Core: rebuild all crates

    /// Rebuilds ALL user-requested crates from scratch in a temporary Cargo project.
    /// This ensures transitive dependencies are correctly resolved and no orphans remain.
    private func rebuildAllCrates(_ userCrates: [String: String]) async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("conjuredsp-crate-build-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir.appendingPathComponent("src"), withIntermediateDirectories: true)

        defer { try? fm.removeItem(at: tempDir) }

        // Write empty lib.rs (cargo needs a source file)
        try "".write(to: tempDir.appendingPathComponent("src/lib.rs"), atomically: true, encoding: .utf8)

        // Write Cargo.toml with all user-requested crates
        var depsSection = ""
        for (name, version) in userCrates.sorted(by: { $0.key < $1.key }) {
            depsSection += "\(name) = \"\(version)\"\n"
        }

        let cargoToml = """
        [package]
        name = "conjuredsp-user-deps"
        version = "0.1.0"
        edition = "2021"

        [dependencies]
        \(depsSection)
        [lib]
        crate-type = ["rlib"]

        [profile.release]
        opt-level = 2
        """
        try cargoToml.write(to: tempDir.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)

        // Run cargo build
        let cargoHome = appGroupURL.appendingPathComponent("cargo-home").path
        try fm.createDirectory(atPath: cargoHome, withIntermediateDirectories: true)

        // Create a rustc wrapper script that sets DYLD_LIBRARY_PATH before exec.
        // macOS SIP strips DYLD_* env vars from child processes of signed binaries,
        // so cargo's spawned rustc won't inherit our DYLD_LIBRARY_PATH directly.
        let rustcWrapper = tempDir.appendingPathComponent("rustc-wrapper.sh")
        let wrapperScript = "#!/bin/bash\nexport DYLD_LIBRARY_PATH=\"\(sysrootPath)/lib\"\nexec \"\(rustcPath)\" --sysroot \"\(sysrootPath)\" \"$@\"\n"
        try wrapperScript.write(to: rustcWrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rustcWrapper.path)

        // Bake --sysroot into the wrapper script instead of RUSTFLAGS,
        // because RUSTFLAGS splits on whitespace and the sysroot path
        // may contain spaces (e.g. "Group Containers").
        var env: [String: String] = [
            "CARGO_HOME": cargoHome,
            "RUSTC": rustcWrapper.path,
            "RUSTUP_TOOLCHAIN": "none",
            "DYLD_LIBRARY_PATH": "\(sysrootPath)/lib",
        ]
        // Inherit PATH for system tools (linker, etc.)
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            env["PATH"] = path
        }

        let args = [
            "build",
            "--release",
            "--target", "wasm32-wasip1",
            "--manifest-path", tempDir.appendingPathComponent("Cargo.toml").path,
        ]

        log.info("Running cargo build with \(userCrates.count) crate(s)")

        // Clear progress file before starting
        let progressURL = appGroupURL.appendingPathComponent(Self.buildProgressFile)
        try? "Downloading crates...".write(to: progressURL, atomically: true, encoding: .utf8)

        let result = await Self.runCargoWithProgress(
            cargoPath, arguments: args, environment: env, progressURL: progressURL
        )

        // Clean up progress file
        try? FileManager.default.removeItem(at: progressURL)

        if result.exitCode != 0 {
            let errMsg = result.output ?? "cargo exited with code \(result.exitCode)"
            log.error("cargo build failed: \(errMsg, privacy: .public)")
            throw CrateInstallerError.buildFailed(errMsg)
        }

        // Harvest rlibs from target/wasm32-wasip1/release/deps/
        let depsDir = tempDir.appendingPathComponent("target/wasm32-wasip1/release/deps")
        try await harvestRlibs(from: depsDir, userCrates: userCrates, lockFile: tempDir.appendingPathComponent("Cargo.lock"))
    }

    /// Copy compiled rlibs to the shared location and write the manifest.
    private func harvestRlibs(from depsDir: URL, userCrates: [String: String], lockFile: URL) async throws {
        let fm = FileManager.default

        // Parse Cargo.lock to get resolved crate versions
        let resolvedVersions = parseLockFile(at: lockFile)

        // Prepare rlib output directory
        let rlibURL = appGroupURL.appendingPathComponent(Self.rlibDir)
        // Clear old rlibs to avoid stale files
        if fm.fileExists(atPath: rlibURL.path) {
            try fm.removeItem(at: rlibURL)
        }
        try fm.createDirectory(at: rlibURL, withIntermediateDirectories: true)

        // Scan for .rlib files in deps directory
        guard fm.fileExists(atPath: depsDir.path),
              let contents = try? fm.contentsOfDirectory(at: depsDir, includingPropertiesForKeys: nil)
        else {
            throw CrateInstallerError.buildFailed("No deps directory found after cargo build")
        }

        var manifestCrates: [String: CrateManifest.CrateEntry] = [:]

        for file in contents {
            let filename = file.lastPathComponent
            guard filename.hasPrefix("lib") && filename.hasSuffix(".rlib") else { continue }

            // Skip std library rlibs (they start with lib followed by std/core/alloc/etc.)
            let stdCrates = ["std", "core", "alloc", "compiler_builtins", "panic_abort",
                             "panic_unwind", "rustc_std_workspace_core", "rustc_std_workspace_alloc",
                             "unwind", "proc_macro", "rustc_demangle", "hashbrown", "cfg_if",
                             "libc", "wasi", "getopts", "unicode_width"]

            // Parse crate name from rlib filename: lib<name>-<hash>.rlib
            let stem = String(filename.dropFirst(3).dropLast(5)) // remove "lib" and ".rlib"
            guard let dashIdx = stem.lastIndex(of: "-") else { continue }
            let crateName = String(stem[..<dashIdx])

            // Skip stdlib crates and the dummy project itself
            if stdCrates.contains(crateName) || crateName == "conjuredsp_user_deps" { continue }

            // Copy rlib to shared location
            let destFile = rlibURL.appendingPathComponent(filename)
            try fm.copyItem(at: file, to: destFile)

            // Determine version from Cargo.lock
            // Crate names in Cargo.lock use hyphens, rlib filenames use underscores
            let normalizedName = crateName.replacingOccurrences(of: "_", with: "-")
            let version = resolvedVersions[normalizedName] ?? resolvedVersions[crateName] ?? "unknown"
            let isUserRequested = userCrates.keys.contains(normalizedName) || userCrates.keys.contains(crateName)

            manifestCrates[crateName] = CrateManifest.CrateEntry(
                version: version,
                rlib: filename,
                userRequested: isUserRequested
            )
        }

        // Write manifest
        let hash = computeManifestHash(manifestCrates.mapValues(\.version))
        let manifest = CrateManifest(
            version: 1,
            rustVersion: rustVersion(),
            crates: manifestCrates,
            manifestHash: hash
        )
        writeManifest(manifest)

        log.info("Harvested \(manifestCrates.count) rlib(s), manifest hash: \(hash.prefix(16), privacy: .public)")
    }

    // MARK: - Cargo.lock parsing

    /// Parse Cargo.lock to extract package name → version mappings.
    private func parseLockFile(at url: URL) -> [String: String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var versions: [String: String] = [:]
        var currentName: String?

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name = ") {
                currentName = trimmed.replacingOccurrences(of: "name = ", with: "")
                    .replacingOccurrences(of: "\"", with: "")
            } else if trimmed.hasPrefix("version = "), let name = currentName {
                let version = trimmed.replacingOccurrences(of: "version = ", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                versions[name] = version
                currentName = nil
            }
        }

        return versions
    }

    // MARK: - Manifest

    private func readManifest() -> CrateManifest? {
        let url = appGroupURL.appendingPathComponent(Self.manifestFile)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CrateManifest.self, from: data)
    }

    private func writeManifest(_ manifest: CrateManifest) {
        let url = appGroupURL.appendingPathComponent(Self.manifestFile)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Returns user-requested crate name → version from the existing manifest.
    private func readExistingUserCrates() -> [String: String] {
        guard let manifest = readManifest() else { return [:] }
        var result: [String: String] = [:]
        for (name, entry) in manifest.crates where entry.userRequested {
            result[name] = entry.version
        }
        return result
    }

    private func computeManifestHash(_ crateVersions: [String: String]) -> String {
        let sorted = crateVersions.sorted(by: { $0.key < $1.key })
        let input = sorted.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func rustVersion() -> String {
        "1.93.1"  // Must match scripts/setup-rustc.sh RUST_VERSION
    }

    // MARK: - Result file

    private func writeResult(_ result: InstallResult) {
        let resultURL = appGroupURL.appendingPathComponent(Self.installResultFile)
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: resultURL, options: .atomic)
        }
    }

    // MARK: - Process execution

    /// Runs cargo and streams stderr "Compiling ..." lines to a progress file
    /// so the AU extension can show real-time build status.
    private static func runCargoWithProgress(
        _ path: String,
        arguments: [String],
        environment: [String: String],
        progressURL: URL
    ) async -> (exitCode: Int32, output: String?) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = environment

            let stderrPipe = Pipe()
            let stdoutPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = stdoutPipe

            // Accumulate all output for error reporting
            let outputLock = NSLock()
            var allOutput = ""

            // Read stderr incrementally to extract "Compiling ..." lines
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

                outputLock.lock()
                allOutput += text
                outputLock.unlock()

                // Extract the last meaningful status line (Compiling, Downloading, Building, etc.)
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines.reversed() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("Compiling ") || trimmed.hasPrefix("Downloading ") ||
                       trimmed.hasPrefix("Building ") || trimmed.hasPrefix("Updating ") {
                        try? trimmed.write(to: progressURL, atomically: true, encoding: .utf8)
                        break
                    }
                }
            }

            process.terminationHandler = { _ in
                // Stop reading handler
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                // Read any remaining stdout
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: stdoutData, encoding: .utf8), !text.isEmpty {
                    outputLock.lock()
                    allOutput += text
                    outputLock.unlock()
                }

                outputLock.lock()
                let finalOutput = allOutput
                outputLock.unlock()

                continuation.resume(returning: (process.terminationStatus, finalOutput))
            }

            do {
                try process.run()
            } catch {
                log.error("Process.run() failed for \(path, privacy: .public): \(error, privacy: .public)")
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    // MARK: - Errors

    enum CrateInstallerError: LocalizedError {
        case buildFailed(String)

        var errorDescription: String? {
            switch self {
            case .buildFailed(let msg): return msg
            }
        }
    }
}
