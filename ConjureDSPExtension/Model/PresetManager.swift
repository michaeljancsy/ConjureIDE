import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PresetManager")

/// Manages discovery, loading, saving, and deletion of DSP script presets.
///
/// Factory presets are read from the extension bundle (read-only).
/// User presets are stored as .py/.rs files in ~/Library/Application Support/ConjureDSP/Presets/.
/// Repo presets are cached locally in ~/Library/Application Support/ConjureDSP/RepoPresets/ and synced to GitHub.
@MainActor
class PresetManager: ObservableObject {
    @Published private(set) var presets: [Preset] = []
    @Published var currentPreset: Preset?
    @Published var isModified: Bool = false

    /// The script source at the time the current preset was loaded, for modification detection.
    private(set) var loadedSource: String?

    /// Called after a repo preset is saved. GitHubService hooks into this to trigger background push.
    var onRepoPresetSaved: ((String, String, ScriptLanguage) -> Void)?

    /// Called after a repo preset is deleted. GitHubService hooks into this to trigger background delete.
    var onRepoPresetDeleted: ((String, ScriptLanguage) -> Void)?

    /// Called after a repo preset is renamed. Parameters: (oldName, newName, source, language).
    var onRepoPresetRenamed: ((String, String, String, ScriptLanguage) -> Void)?

    private let extensionBundle: Bundle
    let userPresetsURL: URL
    let repoPresetsURL: URL
    private let fileManager = FileManager.default

    init(extensionBundle: Bundle) {
        self.extensionBundle = extensionBundle

        let appSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bearBoneDir = appSupport.appendingPathComponent("ConjureDSP", isDirectory: true)
        self.userPresetsURL = bearBoneDir.appendingPathComponent("Presets", isDirectory: true)
        self.repoPresetsURL = bearBoneDir.appendingPathComponent("RepoPresets", isDirectory: true)

        ensureDirectory(userPresetsURL)
        ensureDirectory(repoPresetsURL)
        refreshPresets()
    }

    /// Testable initializer that accepts explicit preset URLs.
    init(extensionBundle: Bundle, userPresetsURL: URL, repoPresetsURL: URL? = nil) {
        self.extensionBundle = extensionBundle
        self.userPresetsURL = userPresetsURL
        self.repoPresetsURL = repoPresetsURL ?? userPresetsURL
            .deletingLastPathComponent()
            .appendingPathComponent("RepoPresets", isDirectory: true)

        ensureDirectory(userPresetsURL)
        ensureDirectory(self.repoPresetsURL)
        refreshPresets()
    }

    // MARK: - Directory Management

    private func ensureDirectory(_ url: URL) {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            log.info("Created directory: \(url.path, privacy: .public)")
        } catch {
            log.error("Failed to create directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Preset Discovery

    /// Supported preset file extensions.
    private static let supportedExtensions: Set<String> = ["py", "rs"]

    func refreshPresets() {
        var result: [Preset] = []

        // Factory presets from bundle
        for entry in FactoryPresetRegistry.entries {
            result.append(Preset(
                id: "factory:\(entry.name)",
                name: entry.name,
                source: .factory(resourceName: entry.resourceName),
                factoryPresetNumber: entry.number,
                language: entry.language,
                category: entry.category
            ))
        }

        // Repo presets from local cache
        result.append(contentsOf: discoverPresets(in: repoPresetsURL, prefix: "repo"))

        // User presets from disk
        result.append(contentsOf: discoverPresets(in: userPresetsURL, prefix: "user"))

        presets = result
    }

    private func discoverPresets(in directory: URL, prefix: String) -> [Preset] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let scriptFiles = files
            .filter { Self.supportedExtensions.contains($0.pathExtension) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        return scriptFiles.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let language: ScriptLanguage = ext == "rs" ? .rust : .python
            let source: Preset.Source = prefix == "repo" ? .repo(url: url) : .user(url: url)
            return Preset(
                id: "\(prefix):\(name).\(ext)",
                name: name,
                source: source,
                factoryPresetNumber: nil,
                language: language,
                category: .other
            )
        }
    }

    // MARK: - Load

    /// Read the source code for a preset.
    func loadSource(for preset: Preset) -> String? {
        switch preset.source {
        case .factory(let resourceName):
            guard let url = extensionBundle.url(forResource: resourceName, withExtension: preset.fileExtension) else {
                log.error("Factory preset resource not found: \(resourceName).\(preset.fileExtension, privacy: .public)")
                return nil
            }
            return try? String(contentsOf: url, encoding: .utf8)
        case .user(let url), .repo(let url):
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// Mark a preset as the currently active one and record its source for modification detection.
    func setCurrentPreset(_ preset: Preset?, source: String?) {
        currentPreset = preset
        loadedSource = source
        isModified = false
    }

    /// Call when the user edits the script to update the modified flag.
    func scriptDidChange(to newSource: String) {
        guard let loaded = loadedSource else {
            isModified = true
            return
        }
        isModified = (newSource != loaded)
    }

    // MARK: - Save (User Presets)

    /// Save source as a new or overwritten user preset. Returns the resulting Preset.
    @discardableResult
    func saveUserPreset(name: String, source: String, language: ScriptLanguage = .python) throws -> Preset {
        let sanitized = sanitizeFilename(name)
        guard !sanitized.isEmpty else {
            throw PresetManagerError.invalidName
        }
        let ext = language == .rust ? "rs" : "py"
        let url = userPresetsURL.appendingPathComponent("\(sanitized).\(ext)")
        try source.write(to: url, atomically: true, encoding: .utf8)
        log.info("Saved user preset: \(sanitized).\(ext, privacy: .public)")

        refreshPresets()

        guard let preset = presets.first(where: { $0.id == "user:\(sanitized).\(ext)" }) else {
            throw PresetManagerError.saveFailed
        }
        return preset
    }

    // MARK: - Save (Repo Presets)

    /// Save source as a repo preset (locally cached + triggers background sync).
    @discardableResult
    func saveRepoPreset(name: String, source: String, language: ScriptLanguage = .python) throws -> Preset {
        let sanitized = sanitizeFilename(name)
        guard !sanitized.isEmpty else {
            throw PresetManagerError.invalidName
        }
        let ext = language == .rust ? "rs" : "py"
        let url = repoPresetsURL.appendingPathComponent("\(sanitized).\(ext)")
        try source.write(to: url, atomically: true, encoding: .utf8)
        log.info("Saved repo preset: \(sanitized).\(ext, privacy: .public)")

        refreshPresets()

        guard let preset = presets.first(where: { $0.id == "repo:\(sanitized).\(ext)" }) else {
            throw PresetManagerError.saveFailed
        }

        onRepoPresetSaved?(sanitized, source, language)
        return preset
    }

    // MARK: - Delete

    /// Delete a user or repo preset. Factory presets cannot be deleted.
    func deletePreset(_ preset: Preset) throws {
        switch preset.source {
        case .factory:
            log.warning("Attempted to delete factory preset: \(preset.name, privacy: .public)")
            return
        case .user(let url):
            try fileManager.removeItem(at: url)
            log.info("Deleted user preset: \(preset.name, privacy: .public)")
        case .repo(let url):
            try fileManager.removeItem(at: url)
            log.info("Deleted repo preset: \(preset.name, privacy: .public)")
            onRepoPresetDeleted?(preset.name, preset.language)
        }

        refreshPresets()

        if currentPreset?.id == preset.id {
            currentPreset = nil
            loadedSource = nil
            isModified = false
        }
    }

    /// Delete a user preset. Factory presets cannot be deleted.
    /// Kept for backward compatibility — delegates to `deletePreset(_:)`.
    func deleteUserPreset(_ preset: Preset) throws {
        try deletePreset(preset)
    }

    // MARK: - Rename

    /// Rename a user or repo preset. Factory presets cannot be renamed.
    /// Returns the renamed preset with updated identity.
    @discardableResult
    func renamePreset(_ preset: Preset, to newName: String) throws -> Preset {
        guard !preset.isFactory else {
            throw PresetManagerError.renameFailed
        }

        let sanitized = sanitizeFilename(newName)
        guard !sanitized.isEmpty else {
            throw PresetManagerError.invalidName
        }

        // No-op if name is unchanged
        guard sanitized != preset.name else { return preset }

        // Check for conflicts with existing non-factory presets
        if presets.contains(where: { !$0.isFactory && $0.name == sanitized }) {
            throw PresetManagerError.nameConflict
        }

        let oldURL: URL
        let prefix: String
        switch preset.source {
        case .factory:
            throw PresetManagerError.renameFailed
        case .user(let url):
            oldURL = url
            prefix = "user"
        case .repo(let url):
            oldURL = url
            prefix = "repo"
        }

        let ext = preset.fileExtension
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent("\(sanitized).\(ext)")
        try fileManager.moveItem(at: oldURL, to: newURL)
        log.info("Renamed preset: \(preset.name, privacy: .public) → \(sanitized, privacy: .public)")

        // For repo presets, trigger background rename on GitHub
        if case .repo = preset.source {
            if let source = try? String(contentsOf: newURL, encoding: .utf8) {
                onRepoPresetRenamed?(preset.name, sanitized, source, preset.language)
            }
        }

        refreshPresets()

        let newID = "\(prefix):\(sanitized).\(ext)"
        guard let renamedPreset = presets.first(where: { $0.id == newID }) else {
            throw PresetManagerError.renameFailed
        }

        // Update current preset reference if it was the renamed one
        if currentPreset?.id == preset.id {
            currentPreset = renamedPreset
        }

        return renamedPreset
    }

    // MARK: - Migration

    /// Move a user preset to the repo cache. Returns the new repo Preset.
    /// Set `triggerSync: false` when the caller has already pushed to GitHub (e.g. during migration).
    @discardableResult
    func migrateUserPresetToRepo(_ preset: Preset, triggerSync: Bool = true) throws -> Preset {
        guard case .user(let sourceURL) = preset.source else {
            throw PresetManagerError.saveFailed
        }
        let destURL = repoPresetsURL.appendingPathComponent(sourceURL.lastPathComponent)
        try fileManager.moveItem(at: sourceURL, to: destURL)
        log.info("Migrated preset to repo: \(preset.name, privacy: .public)")

        if triggerSync, let source = try? String(contentsOf: destURL, encoding: .utf8) {
            onRepoPresetSaved?(preset.name, source, preset.language)
        }

        refreshPresets()

        let ext = preset.fileExtension
        return presets.first(where: { $0.id == "repo:\(preset.name).\(ext)" }) ?? preset
    }

    // MARK: - Name Helpers

    /// Returns a unique name by appending " 2", " 3", etc. if baseName already exists.
    func uniqueName(baseName: String) -> String {
        let existing = Set(presets.map { $0.name })
        if !existing.contains(baseName) { return baseName }
        for i in 2...999 {
            let candidate = "\(baseName) \(i)"
            if !existing.contains(candidate) { return candidate }
        }
        return "\(baseName) \(UUID().uuidString.prefix(4))"
    }

    /// Check whether a user or repo preset with this name already exists.
    func userPresetExists(name: String) -> Bool {
        let sanitized = sanitizeFilename(name)
        return presets.contains { !$0.isFactory && $0.name == sanitized }
    }

    /// Replace filesystem-unsafe characters and trim whitespace.
    func sanitizeFilename(_ name: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: unsafe)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
    }
}

enum PresetManagerError: LocalizedError {
    case invalidName
    case saveFailed
    case renameFailed
    case nameConflict

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Preset name is invalid"
        case .saveFailed: return "Failed to save preset"
        case .renameFailed: return "Failed to rename preset"
        case .nameConflict: return "A preset with that name already exists"
        }
    }
}
