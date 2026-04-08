//
//  CrateInstallManager.swift
//  ConjureDSPExtension
//
//  Manages Rust crate installation via App Group signaling to the companion app.
//  The AU extension writes install/uninstall requests; the companion app uses
//  cargo to compile crates to wasm32-wasip1 rlibs and writes results back.
//

import Foundation
import CryptoKit
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "Crates")

@Observable
@MainActor
final class CrateInstallManager {
    private static let installRequestFile = "crate-install-request.json"
    private static let installResultFile = "crate-install-result.json"
    private static let uninstallRequestFile = "crate-uninstall-request.json"
    private static let buildProgressFile = "crate-build-progress.txt"
    private static let manifestFile = "RustCrates/manifest.json"
    private static let rlibDir = "RustCrates/lib"

    // MARK: - Observable State

    private(set) var isInstalling = false
    private(set) var installStatusMessage: String?
    private(set) var lastError: String?
    private(set) var installedCrates: [InstalledCrate] = []

    // MARK: - Models

    struct InstalledCrate: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let version: String
        let isBundled: Bool
    }

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
        let crates: [String: CrateEntry]
        let manifestHash: String

        struct CrateEntry: Codable {
            let version: String
            let rlib: String
            let userRequested: Bool
        }
    }

    /// The only built-in crate (linked by RustCompiler from the sysroot).
    static let bundledCrates: Set<String> = ["conjuredsp"]

    // MARK: - State

    private var resultPollTimer: Timer?
    private var pendingRequestId: String?
    private var pendingCrateNames: String?
    private var pendingIsUninstall = false
    private var pollStartTime: Date?
    private static let pollTimeoutSeconds: TimeInterval = 300  // cargo compiles from source; first build downloads + compiles all deps

    /// Callback fired when crates change (install/uninstall). Use to trigger script reload.
    var onCratesChanged: (() -> Void)?

    // MARK: - Init

    init() {
        refreshInstalledCrates()
    }

    // MARK: - Install

    func requestInstall(crates: [CrateSpec]) {
        guard !isInstalling else {
            lastError = "Please wait for the current operation to finish"
            return
        }
        let containerURL = appGroupContainerURL()

        // Check if the Rust toolchain is provisioned (cargo must exist)
        let cargoPath = containerURL.appendingPathComponent("rustc-dist/bin/cargo").path
        if !FileManager.default.fileExists(atPath: cargoPath) {
            lastError = "Rust toolchain not available. Restart ConjureDSP Terminal (re-run scripts/setup-rustc.sh if cargo is missing)."
            return
        }

        let requestId = UUID().uuidString
        let request = InstallRequest(
            requestId: requestId,
            crates: crates,
            timestamp: Date().timeIntervalSince1970
        )

        let requestURL = containerURL.appendingPathComponent(Self.installRequestFile)
        let resultURL = containerURL.appendingPathComponent(Self.installResultFile)
        try? FileManager.default.removeItem(at: resultURL)

        do {
            let data = try JSONEncoder().encode(request)
            try data.write(to: requestURL, options: .atomic)
            pendingRequestId = requestId
            isInstalling = true
            let names = crates.map(\.name).joined(separator: ", ")
            pendingCrateNames = names
            pendingIsUninstall = false
            installStatusMessage = "Building \(names)..."
            lastError = nil
            log.info("Wrote crate install request for \(names, privacy: .public)")
            startPollingForResult()
        } catch {
            lastError = "Failed to write install request: \(error.localizedDescription)"
        }
    }

    // MARK: - Uninstall

    func requestUninstall(crateName: String) {
        guard !isInstalling else {
            lastError = "Please wait for the current operation to finish"
            return
        }
        let normalized = crateName.lowercased().replacingOccurrences(of: "_", with: "-")
        guard !Self.bundledCrates.contains(normalized) else {
            lastError = "\(crateName) is a built-in crate and cannot be removed"
            return
        }
        let containerURL = appGroupContainerURL()

        let cargoPath = containerURL.appendingPathComponent("rustc-dist/bin/cargo").path
        if !FileManager.default.fileExists(atPath: cargoPath) {
            lastError = "Rust toolchain not available. Restart ConjureDSP Terminal (re-run scripts/setup-rustc.sh if cargo is missing)."
            return
        }

        let requestId = UUID().uuidString
        let request = UninstallRequest(
            requestId: requestId,
            crates: [crateName],
            timestamp: Date().timeIntervalSince1970
        )

        let requestURL = containerURL.appendingPathComponent(Self.uninstallRequestFile)
        let resultURL = containerURL.appendingPathComponent(Self.installResultFile)
        try? FileManager.default.removeItem(at: resultURL)

        do {
            let data = try JSONEncoder().encode(request)
            try data.write(to: requestURL, options: .atomic)
            pendingRequestId = requestId
            isInstalling = true
            pendingCrateNames = crateName
            pendingIsUninstall = true
            installStatusMessage = "Removing \(crateName)..."
            lastError = nil
            log.info("Wrote crate uninstall request for \(crateName, privacy: .public)")
            startPollingForResult()
        } catch {
            lastError = "Failed to write uninstall request: \(error.localizedDescription)"
        }
    }

    // MARK: - Result Polling

    private func startPollingForResult() {
        resultPollTimer?.invalidate()
        pollStartTime = Date()
        resultPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForResult()
            }
        }
    }

    private func timeoutPolling() {
        resultPollTimer?.invalidate()
        resultPollTimer = nil
        pendingRequestId = nil
        pendingCrateNames = nil
        pollStartTime = nil
        isInstalling = false
        installStatusMessage = nil
        lastError = "Operation timed out. Is ConjureDSP Terminal running?"
        log.error("Crate install/uninstall timed out after \(Self.pollTimeoutSeconds)s")
        SentryHelper.capture("Crate install timed out", level: .warning, category: "crates")
    }

    func checkForResult() {
        if let start = pollStartTime, Date().timeIntervalSince(start) > Self.pollTimeoutSeconds {
            timeoutPolling()
            return
        }

        // Update status with cargo progress and elapsed time (installs only —
        // uninstalls show "Removing <name>..." without cargo noise)
        if let start = pollStartTime, !pendingIsUninstall {
            let containerURL = appGroupContainerURL()
            let elapsed = Int(Date().timeIntervalSince(start))
            let progressURL = containerURL.appendingPathComponent(Self.buildProgressFile)
            let progress = (try? String(contentsOf: progressURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let progress, !progress.isEmpty {
                installStatusMessage = "\(progress) (\(elapsed)s)"
            } else {
                let baseName = pendingCrateNames ?? "crates"
                installStatusMessage = "Building \(baseName)... (\(elapsed)s)"
            }
        }

        let containerURL = appGroupContainerURL()
        let resultURL = containerURL.appendingPathComponent(Self.installResultFile)

        guard FileManager.default.fileExists(atPath: resultURL.path),
              let data = try? Data(contentsOf: resultURL),
              let result = try? JSONDecoder().decode(InstallResult.self, from: data)
        else { return }

        guard result.requestId == pendingRequestId else {
            try? FileManager.default.removeItem(at: resultURL)
            return
        }

        try? FileManager.default.removeItem(at: resultURL)

        pendingRequestId = nil
        let wasUninstall = pendingIsUninstall
        pendingCrateNames = nil
        pendingIsUninstall = false
        isInstalling = false
        installStatusMessage = nil
        resultPollTimer?.invalidate()
        resultPollTimer = nil

        if result.success {
            log.info("Crate operation succeeded: \(result.crates.joined(separator: ", "), privacy: .public)")
            lastError = nil
            let names = result.crates.joined(separator: ", ")
            let verb = wasUninstall ? "Removed" : "Installed"
            installStatusMessage = "\(verb) \(names) ✓"
            refreshInstalledCrates()
            onCratesChanged?()
            // Auto-clear success message after 3 seconds
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if self.installStatusMessage?.hasSuffix("✓") == true {
                    self.installStatusMessage = nil
                }
            }
        } else {
            let rawError = result.error ?? "Unknown error"
            log.error("Crate operation failed: \(rawError, privacy: .public)")
            lastError = Self.userFriendlyError(rawError)
            let names = result.crates.joined(separator: ", ")
            let operation = wasUninstall ? "uninstall" : "install"
            SentryHelper.capture(
                "Crate \(operation) failed: \(names)",
                level: .error,
                category: "crates",
                extra: ["crates": names, "error": rawError]
            )
        }
    }

    // MARK: - Installed Crates

    func refreshInstalledCrates() {
        guard let manifest = Self.readManifest() else {
            installedCrates = [InstalledCrate(name: "conjuredsp", version: "built-in", isBundled: true)]
            return
        }

        var crates: [InstalledCrate] = [
            InstalledCrate(name: "conjuredsp", version: "built-in", isBundled: true),
        ]

        for (name, entry) in manifest.crates where entry.userRequested {
            crates.append(InstalledCrate(name: name, version: entry.version, isBundled: false))
        }

        installedCrates = crates.sorted {
            if $0.isBundled != $1.isBundled { return $0.isBundled }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    // MARK: - Static helpers for RustCompiler integration
    // These are nonisolated because RustCompiler calls them from non-main-actor context.
    // They only read files and don't touch observable state.

    /// Read the crate manifest from the App Group container.
    nonisolated static func readManifest() -> CrateManifest? {
        let url = containerURL().appendingPathComponent(manifestFile)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CrateManifest.self, from: data)
    }

    /// Returns the manifest hash for WasmCache invalidation, or nil if no crates installed.
    nonisolated static func readManifestHash() -> String? {
        readManifest()?.manifestHash
    }

    /// Returns `--extern` argument pairs for all installed crate rlibs.
    /// Each pair is (crate_name, full_rlib_path). Names use underscores
    /// (Rust identifier form) since they're passed to rustc `--extern`.
    nonisolated static func externArgs() -> [(name: String, path: String)] {
        guard let manifest = readManifest() else { return [] }
        let libDir = cratesLibURL().path

        return manifest.crates.compactMap { (name, entry) in
            let path = "\(libDir)/\(entry.rlib)"
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            // Manifest keys use hyphens (crates.io canonical); rustc --extern needs underscores
            let rustName = name.replacingOccurrences(of: "-", with: "_")
            return (name: rustName, path: path)
        }
    }

    /// Returns the directory containing installed rlibs, for rustc `-L` flag.
    nonisolated static func cratesLibURL() -> URL {
        containerURL().appendingPathComponent(rlibDir)
    }

    // MARK: - Error messages

    /// Prepends a user-friendly explanation to cargo errors when the failure is a
    /// recognizable class (e.g. build script failures during cross-compilation).
    private static func userFriendlyError(_ raw: String) -> String {
        // Build script failures: the crate has native/system dependencies that
        // can't cross-compile to WebAssembly (e.g. pyo3, openssl-sys, cmake).
        if raw.contains("failed to run custom build command for") {
            return "This crate has a build script that failed during WebAssembly cross-compilation. "
                + "It likely depends on system libraries or native bindings not available in WASM.\n\n"
                + raw
        }
        return raw
    }

    // MARK: - Helpers

    private func appGroupContainerURL() -> URL {
        Self.containerURL()
    }

    nonisolated private static func containerURL() -> URL {
        AppGroupContainer.url
    }
}
