//
//  PackageInstallManager.swift
//  ConjureDSPExtension
//
//  Manages Python package installation via App Group signaling to the companion app.
//  The AU extension writes install/uninstall requests; the companion app processes them
//  and writes results back. Polls for results on a timer.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "Packages")

@Observable
@MainActor
final class PackageInstallManager {
    private static let appGroupID = "group.com.MichaelJancsy.ConjureDSP"
    private static let installRequestFile = "package-install-request.json"
    private static let installResultFile = "package-install-result.json"
    private static let uninstallRequestFile = "package-uninstall-request.json"

    // MARK: - Observable State

    private(set) var isInstalling = false
    private(set) var installStatusMessage: String?
    private(set) var lastError: String?
    private(set) var installedPackages: [InstalledPackage] = []

    // MARK: - Models

    struct InstalledPackage: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let version: String
    }

    struct InstallRequest: Codable {
        let requestId: String
        let packages: [String]
        let targetPath: String
        let pythonHomePath: String
        let timestamp: Double
    }

    struct UninstallRequest: Codable {
        let requestId: String
        let packages: [String]
        let targetPath: String
        let timestamp: Double
    }

    struct InstallResult: Codable {
        let requestId: String
        let success: Bool
        let packages: [String]
        let error: String?
        let timestamp: Double
    }

    // MARK: - State

    private var resultPollTimer: Timer?
    private var pendingRequestId: String?
    private var pollStartTime: Date?
    private static let pollTimeoutSeconds: TimeInterval = 30
    private let pythonHomePath: String?

    /// Callback fired when packages change (install/uninstall). Use to trigger script reload.
    var onPackagesChanged: (() -> Void)?

    // MARK: - Init

    init(pythonHomePath: String?) {
        self.pythonHomePath = pythonHomePath
        refreshInstalledPackages()
    }

    // MARK: - Install

    /// Request package installation via the companion app.
    func requestInstall(packages: [String]) {
        guard let pythonHome = pythonHomePath else {
            lastError = "Python runtime not available"
            return
        }
        let pythonBin = URL(fileURLWithPath: pythonHome).appendingPathComponent("bin/python3").path
        guard FileManager.default.fileExists(atPath: pythonBin) else {
            lastError = "Python runtime not installed. Open the ConjureDSP app at least once to set it up."
            return
        }
        guard let containerURL = appGroupContainerURL() else {
            lastError = "App Group container not available"
            return
        }

        let targetPath = ConjureDSPExtensionAudioUnit.userPackagesURL.path
        let requestId = UUID().uuidString
        let request = InstallRequest(
            requestId: requestId,
            packages: packages,
            targetPath: targetPath,
            pythonHomePath: pythonHome,
            timestamp: Date().timeIntervalSince1970
        )

        let requestURL = containerURL.appendingPathComponent(Self.installRequestFile)
        // Remove any stale result file before writing new request
        let resultURL = containerURL.appendingPathComponent(Self.installResultFile)
        try? FileManager.default.removeItem(at: resultURL)

        do {
            let data = try JSONEncoder().encode(request)
            try data.write(to: requestURL, options: .atomic)
            pendingRequestId = requestId
            isInstalling = true
            installStatusMessage = "Installing \(packages.joined(separator: ", "))..."
            lastError = nil
            log.info("Wrote install request for \(packages.joined(separator: ", "), privacy: .public)")
            startPollingForResult()
        } catch {
            lastError = "Failed to write install request: \(error.localizedDescription)"
            log.error("Failed to write install request: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Uninstall

    /// Request package removal via the companion app.
    func requestUninstall(packageName: String) {
        guard let containerURL = appGroupContainerURL() else {
            lastError = "App Group container not available"
            return
        }

        let targetPath = ConjureDSPExtensionAudioUnit.userPackagesURL.path
        let requestId = UUID().uuidString
        let request = UninstallRequest(
            requestId: requestId,
            packages: [packageName],
            targetPath: targetPath,
            timestamp: Date().timeIntervalSince1970
        )

        let requestURL = containerURL.appendingPathComponent(Self.uninstallRequestFile)
        // Remove any stale result file before writing new request
        let resultURL = containerURL.appendingPathComponent(Self.installResultFile)
        try? FileManager.default.removeItem(at: resultURL)

        do {
            let data = try JSONEncoder().encode(request)
            try data.write(to: requestURL, options: .atomic)
            pendingRequestId = requestId
            isInstalling = true
            installStatusMessage = "Removing \(packageName)..."
            lastError = nil
            log.info("Wrote uninstall request for \(packageName, privacy: .public)")
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
        pollStartTime = nil
        isInstalling = false
        installStatusMessage = nil
        lastError = "Operation timed out. Is ConjureDSP app running?"
        log.error("Package install/uninstall timed out after \(Self.pollTimeoutSeconds)s — companion app not responding")
    }

    func checkForResult() {
        // Time out if companion app hasn't responded within the timeout window
        if let start = pollStartTime, Date().timeIntervalSince(start) > Self.pollTimeoutSeconds {
            timeoutPolling()
            return
        }

        guard let containerURL = appGroupContainerURL() else { return }
        let resultURL = containerURL.appendingPathComponent(Self.installResultFile)

        guard FileManager.default.fileExists(atPath: resultURL.path),
              let data = try? Data(contentsOf: resultURL),
              let result = try? JSONDecoder().decode(InstallResult.self, from: data)
        else { return }

        // Ignore results that don't match the pending request
        guard result.requestId == pendingRequestId else {
            // Stale result file — clean it up and keep polling
            try? FileManager.default.removeItem(at: resultURL)
            return
        }

        // Clean up result file
        try? FileManager.default.removeItem(at: resultURL)

        // Update state
        pendingRequestId = nil
        isInstalling = false
        installStatusMessage = nil
        resultPollTimer?.invalidate()
        resultPollTimer = nil

        if result.success {
            log.info("Package operation succeeded: \(result.packages.joined(separator: ", "), privacy: .public)")
            lastError = nil
            refreshInstalledPackages()
            onPackagesChanged?()
        } else {
            let errorMsg = result.error ?? "Unknown error"
            log.error("Package operation failed: \(errorMsg, privacy: .public)")
            lastError = errorMsg
        }
    }

    // MARK: - Installed Packages

    /// Scan user-packages directory to discover installed packages.
    func refreshInstalledPackages() {
        let userPkgsURL = ConjureDSPExtensionAudioUnit.userPackagesURL
        let fm = FileManager.default

        guard fm.fileExists(atPath: userPkgsURL.path) else {
            installedPackages = []
            return
        }

        // Look for *.dist-info directories (standard pip/uv metadata)
        guard let contents = try? fm.contentsOfDirectory(
            at: userPkgsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            installedPackages = []
            return
        }

        var packages: [InstalledPackage] = []
        for item in contents {
            let name = item.lastPathComponent
            if name.hasSuffix(".dist-info") {
                // Format: package_name-1.2.3.dist-info
                let stem = String(name.dropLast(".dist-info".count))
                if let dashRange = stem.range(of: "-", options: .backwards) {
                    let pkgName = String(stem[..<dashRange.lowerBound])
                        .replacingOccurrences(of: "_", with: "-")
                    let version = String(stem[dashRange.upperBound...])
                    packages.append(InstalledPackage(name: pkgName, version: version))
                }
            }
        }

        installedPackages = packages.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Helpers

    private func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        )
    }
}
