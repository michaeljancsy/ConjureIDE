//
//  LanguageModuleCatalog.swift
//  Shared between ConjureDSPExtension and ConjureDSPTerminal
//
//  Defines the on-disk schema for:
//  - catalog.json — the remote manifest of available language modules
//  - <module>/manifest.json — written inside each installed module directory
//  - App Group IPC request/result files
//
//  Keep this file identical across the two targets. Both add it as a source
//  reference (no module import needed — plain Swift structs).
//

import Foundation

// MARK: - Remote catalog (catalog.json on R2)

/// Top-level document fetched from `<base>/language-modules/catalog.json`.
struct LanguageModuleCatalog: Codable, Sendable {
    let schemaVersion: Int
    let modules: [String: LanguageModuleSpec]
}

/// One entry in `catalog.json`. Describes a module that CAN be installed.
struct LanguageModuleSpec: Codable, Sendable {
    /// Semantic version of this module's payload (e.g. "3.14.3").
    let version: String
    /// Download size in megabytes — shown in the UI before the user commits.
    let sizeMB: Double
    /// SHA256 of the downloaded tarball, hex-encoded (lowercase).
    let sha256: String
    /// Minimum host-app version that supports this module.
    let minApp: String
    /// Tarball URL. If omitted, derived as `<catalogBase>/<name>-<version>-aarch64.tar.gz`.
    let url: String?
    /// Optional: commercial-license gate identifier. If non-nil, install is
    /// blocked unless the user has satisfied the named license. Used for
    /// CMajor and anything else with third-party commercial licensing.
    let licenseGate: String?
    /// Optional: human-readable description for the UI.
    let description: String?
}

// MARK: - Local manifest (written by the downloader into each module dir)

/// Written to `<AppGroup>/LanguageModules/<name>/manifest.json` after a
/// successful install. The extension's LanguageModuleManager reads this to
/// enumerate what's on disk, independent of the remote catalog.
struct InstalledLanguageModuleManifest: Codable, Sendable {
    let name: String
    let version: String
    let installedAt: Double
    let sha256: String
    /// Size on disk after extraction, in bytes. Used to show accurate disk usage.
    let installedBytes: UInt64
    /// Relative paths to key runtime files, so backends can locate them quickly
    /// without walking the tree. Interpretation is module-specific.
    let entrypoints: [String: String]
}

// MARK: - IPC payloads (request/result files at App Group root)

struct LanguageInstallRequest: Codable, Sendable {
    let requestId: String
    let moduleName: String
    let version: String
    /// Source of truth for the download URL — snapshotted at request time so
    /// the downloader doesn't have to re-resolve the catalog.
    let url: String
    let sha256: String
    let timestamp: Double
}

struct LanguageUninstallRequest: Codable, Sendable {
    let requestId: String
    let moduleName: String
    let timestamp: Double
}

struct LanguageInstallResult: Codable, Sendable {
    let requestId: String
    let moduleName: String
    let success: Bool
    let error: String?
    let timestamp: Double
}

// MARK: - Constants

/// Shared on-disk filenames. Used by both the extension (writer) and the
/// companion app (reader).
enum LanguageModuleIPC {
    static let installRequestFile = "language-install-request.json"
    static let uninstallRequestFile = "language-uninstall-request.json"
    static let installResultFile = "language-install-result.json"
    static let downloadProgressFile = "language-download-progress.txt"
    static let modulesDirectory = "LanguageModules"
    static let manifestFile = "manifest.json"
}

/// Default catalog URL. Override at build time or via UserDefaults
/// `ConjureDSPLanguageCatalogURL` for local development.
///
/// Reuses the same R2 bucket as the main-app appcast
/// (`conjuredsp-updates`, fronted by `updates.conjuredsp.com`) rather than
/// standing up a separate bucket — scripts/publish-language-catalog.sh
/// uploads modules and this JSON under /language-modules/. If we later
/// move to a dedicated domain, update this URL and the script together.
enum LanguageCatalog {
    static let defaultCatalogURL = URL(string: "https://updates.conjuredsp.com/language-modules/catalog.json")!

    static func resolvedCatalogURL() -> URL {
        if let override = UserDefaults.standard.string(forKey: "ConjureDSPLanguageCatalogURL"),
           let url = URL(string: override) {
            return url
        }
        return defaultCatalogURL
    }
}
