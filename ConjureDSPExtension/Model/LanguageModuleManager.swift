//
//  LanguageModuleManager.swift
//  ConjureDSPExtension
//
//  Manages optional DSP-language runtime modules (Python, Rust compiler, Lua,
//  libpd, WASI SDK, CMajor) that are downloaded on demand. Communicates with
//  the companion app via App Group IPC using the same request/result/progress
//  file protocol as CrateInstallManager.
//
//  Phase 1 scope: plumbing only. No module is downloaded by default; the
//  catalog may be empty. All existing bundled languages (Python, Rust) keep
//  working because their backend code is still statically linked and falls
//  back to the in-bundle runtime when no language module is installed.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "LanguageModules")

@Observable
@MainActor
final class LanguageModuleManager {
    // MARK: - Observable state

    private(set) var isInstalling = false
    private(set) var installStatusMessage: String?
    private(set) var lastError: String?
    private(set) var installedModules: [InstalledModule] = []
    private(set) var catalog: LanguageModuleCatalog?

    // MARK: - Models

    struct InstalledModule: Identifiable, Hashable, Sendable {
        var id: String { name }
        let name: String
        let version: String
        let installedBytes: UInt64
    }

    // MARK: - Polling state

    private var resultPollTimer: Timer?
    private var pendingRequestId: String?
    private var pendingModuleName: String?
    private var pendingIsUninstall = false
    private var pollStartTime: Date?
    private static let pollTimeoutSeconds: TimeInterval = 900  // big tarballs can take minutes

    /// Fired after a successful install/uninstall so the extension can retry
    /// any backend that was previously blocked waiting on a module.
    var onModulesChanged: (() -> Void)?

    // MARK: - Init

    init() {
        refreshInstalledModules()
    }

    // MARK: - Error handling

    /// Clears any displayed error message. Called by the UI before a refresh.
    func clearError() {
        lastError = nil
    }

    // MARK: - Catalog loading

    /// Fetches the remote module catalog. Safe to call anytime; updates the
    /// `catalog` property on success, sets `lastError` on failure.
    func loadCatalog() async {
        let url = LanguageCatalog.resolvedCatalogURL()
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                lastError = "Catalog fetch failed (HTTP \(code))"
                log.error("Catalog fetch returned non-200: \(code)")
                return
            }
            let decoded = try JSONDecoder().decode(LanguageModuleCatalog.self, from: data)
            self.catalog = decoded
            log.info("Loaded catalog with \(decoded.modules.count) module(s)")
        } catch {
            lastError = "Catalog fetch failed: \(error.localizedDescription)"
            log.error("Catalog fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Install

    /// Resolves `moduleName` against the loaded catalog and kicks off an install.
    /// Call `loadCatalog()` first so `catalog` is populated.
    func requestInstall(moduleName: String) {
        guard !isInstalling else {
            lastError = "Please wait for the current operation to finish"
            return
        }
        guard let catalog else {
            lastError = "Catalog not loaded — try Refresh"
            return
        }
        guard let spec = catalog.modules[moduleName] else {
            lastError = "Module '\(moduleName)' is not in the catalog"
            return
        }

        let resolvedURL = spec.url ?? Self.defaultTarballURL(
            moduleName: moduleName,
            version: spec.version
        )
        guard let url = URL(string: resolvedURL) else {
            lastError = "Module '\(moduleName)' has an invalid URL"
            return
        }

        let requestId = UUID().uuidString
        let request = LanguageInstallRequest(
            requestId: requestId,
            moduleName: moduleName,
            version: spec.version,
            url: url.absoluteString,
            sha256: spec.sha256,
            timestamp: Date().timeIntervalSince1970
        )

        let container = Self.containerURL()
        let requestURL = container.appendingPathComponent(LanguageModuleIPC.installRequestFile)
        let resultURL = container.appendingPathComponent(LanguageModuleIPC.installResultFile)
        try? FileManager.default.removeItem(at: resultURL)

        do {
            let data = try JSONEncoder().encode(request)
            try data.write(to: requestURL, options: .atomic)
            pendingRequestId = requestId
            pendingModuleName = moduleName
            pendingIsUninstall = false
            isInstalling = true
            installStatusMessage = "Downloading \(moduleName) \(spec.version)..."
            lastError = nil
            log.info("Wrote language install request for \(moduleName, privacy: .public) \(spec.version, privacy: .public)")
            startPollingForResult()
        } catch {
            lastError = "Failed to write install request: \(error.localizedDescription)"
        }
    }

    // MARK: - Uninstall

    func requestUninstall(moduleName: String) {
        guard !isInstalling else {
            lastError = "Please wait for the current operation to finish"
            return
        }

        let requestId = UUID().uuidString
        let request = LanguageUninstallRequest(
            requestId: requestId,
            moduleName: moduleName,
            timestamp: Date().timeIntervalSince1970
        )

        let container = Self.containerURL()
        let requestURL = container.appendingPathComponent(LanguageModuleIPC.uninstallRequestFile)
        let resultURL = container.appendingPathComponent(LanguageModuleIPC.installResultFile)
        try? FileManager.default.removeItem(at: resultURL)

        do {
            let data = try JSONEncoder().encode(request)
            try data.write(to: requestURL, options: .atomic)
            pendingRequestId = requestId
            pendingModuleName = moduleName
            pendingIsUninstall = true
            isInstalling = true
            installStatusMessage = "Removing \(moduleName)..."
            lastError = nil
            log.info("Wrote language uninstall request for \(moduleName, privacy: .public)")
            startPollingForResult()
        } catch {
            lastError = "Failed to write uninstall request: \(error.localizedDescription)"
        }
    }

    // MARK: - Result polling

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
        pendingModuleName = nil
        isInstalling = false
        installStatusMessage = nil
        lastError = "Operation timed out. Is ConjureDSP Terminal running?"
        log.error("Language module operation timed out after \(Self.pollTimeoutSeconds)s")
    }

    private func checkForResult() {
        if let start = pollStartTime, Date().timeIntervalSince(start) > Self.pollTimeoutSeconds {
            timeoutPolling()
            return
        }

        let container = Self.containerURL()

        // Update status with download/extract progress + elapsed time
        if let start = pollStartTime, !pendingIsUninstall {
            let elapsed = Int(Date().timeIntervalSince(start))
            let progressURL = container.appendingPathComponent(LanguageModuleIPC.downloadProgressFile)
            let progress = (try? String(contentsOf: progressURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let progress, !progress.isEmpty {
                installStatusMessage = "\(progress) (\(elapsed)s)"
            } else if let name = pendingModuleName {
                installStatusMessage = "Downloading \(name)... (\(elapsed)s)"
            }
        }

        let resultURL = container.appendingPathComponent(LanguageModuleIPC.installResultFile)
        guard FileManager.default.fileExists(atPath: resultURL.path),
              let data = try? Data(contentsOf: resultURL),
              let result = try? JSONDecoder().decode(LanguageInstallResult.self, from: data)
        else { return }

        guard result.requestId == pendingRequestId else {
            try? FileManager.default.removeItem(at: resultURL)
            return
        }

        try? FileManager.default.removeItem(at: resultURL)

        let wasUninstall = pendingIsUninstall
        let name = result.moduleName
        pendingRequestId = nil
        pendingModuleName = nil
        pendingIsUninstall = false
        isInstalling = false
        resultPollTimer?.invalidate()
        resultPollTimer = nil

        if result.success {
            log.info("Language module \(wasUninstall ? "uninstall" : "install", privacy: .public) succeeded: \(name, privacy: .public)")
            lastError = nil
            let verb = wasUninstall ? "Removed" : "Installed"
            installStatusMessage = "\(verb) \(name) ✓"
            refreshInstalledModules()
            onModulesChanged?()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if self.installStatusMessage?.hasSuffix("✓") == true {
                    self.installStatusMessage = nil
                }
            }
        } else {
            let raw = result.error ?? "Unknown error"
            log.error("Language module \(wasUninstall ? "uninstall" : "install", privacy: .public) failed: \(raw, privacy: .public)")
            lastError = raw
            installStatusMessage = nil
        }
    }

    // MARK: - Refresh installed modules

    func refreshInstalledModules() {
        let container = Self.containerURL()
        let modulesDir = container.appendingPathComponent(LanguageModuleIPC.modulesDirectory)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: modulesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            installedModules = []
            return
        }

        var result: [InstalledModule] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            let manifestURL = entry.appendingPathComponent(LanguageModuleIPC.manifestFile)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(InstalledLanguageModuleManifest.self, from: data)
            else { continue }

            result.append(InstalledModule(
                name: manifest.name,
                version: manifest.version,
                installedBytes: manifest.installedBytes
            ))
        }

        installedModules = result.sorted { $0.name < $1.name }
    }

    // MARK: - Static helpers

    /// Default tarball URL derivation when `catalog.url` is nil.
    static func defaultTarballURL(moduleName: String, version: String) -> String {
        let base = LanguageCatalog.resolvedCatalogURL()
            .deletingLastPathComponent()  // strip "/catalog.json"
            .absoluteString
        return "\(base)/\(moduleName)-\(version)-aarch64.tar.gz"
    }

    /// App Group container URL. Nonisolated so backends (off-main) can read it.
    nonisolated static func containerURL() -> URL {
        AppGroupContainer.url
    }

    /// Returns the directory for a specific installed module, e.g.
    /// `<AppGroup>/LanguageModules/python`. Path exists iff the module is installed.
    nonisolated static func moduleDirectory(for name: String) -> URL {
        containerURL()
            .appendingPathComponent(LanguageModuleIPC.modulesDirectory)
            .appendingPathComponent(name)
    }

    /// Probe: is the named module installed? Nonisolated so Rust-bridge code
    /// and backend init paths can call it without hopping to main.
    nonisolated static func isInstalled(_ name: String) -> Bool {
        let manifestURL = moduleDirectory(for: name)
            .appendingPathComponent(LanguageModuleIPC.manifestFile)
        return FileManager.default.fileExists(atPath: manifestURL.path)
    }
}
