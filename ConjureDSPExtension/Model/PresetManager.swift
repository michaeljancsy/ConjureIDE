import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PresetManager")

/// Manages discovery, loading, saving, and deletion of DSP script presets.
///
/// Factory presets are read from the extension bundle (read-only).
/// User presets are stored as .py/.rs files in the App Group container
/// under `Presets/`, which is a git repository managed by PresetGitCoordinator.
@MainActor
class PresetManager: ObservableObject {
    @Published private(set) var presets: [Preset] = []
    @Published var currentPreset: Preset?
    @Published var isModified: Bool = false

    /// The script source at the time the current preset was loaded, for modification detection.
    private(set) var loadedSource: String?

    /// Fired after a user preset is written (saved, renamed, deleted).
    /// PresetGitCoordinator hooks into this to stage + commit the change.
    /// `oldName` is non-nil only for renames.
    var onPresetWritten: ((Preset, _ oldName: String?) -> Void)?

    /// Fired after a user preset file is removed from disk. Used by
    /// PresetGitCoordinator so the removal is staged + committed.
    var onPresetDeleted: ((_ name: String, _ url: URL, _ language: ScriptLanguage) -> Void)?

    private let extensionBundle: Bundle
    let presetsURL: URL
    private let fileManager = FileManager.default

    init(extensionBundle: Bundle) {
        self.extensionBundle = extensionBundle

        let baseDir = AppGroupContainer.url
        self.presetsURL = baseDir.appendingPathComponent("Presets", isDirectory: true)

        ensureDirectory(presetsURL)
        refreshPresets()
    }

    /// Testable initializer that accepts an explicit preset URL.
    init(extensionBundle: Bundle, presetsURL: URL) {
        self.extensionBundle = extensionBundle
        self.presetsURL = presetsURL

        ensureDirectory(presetsURL)
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

        // User presets from disk
        result.append(contentsOf: discoverPresets(in: presetsURL))

        presets = result
    }

    private func discoverPresets(in directory: URL) -> [Preset] {
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
            return Preset(
                id: "user:\(name).\(ext)",
                name: name,
                source: .user(url: url),
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
        case .user(let url):
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

    // MARK: - Save

    /// Save source as a new or overwritten user preset. Returns the resulting Preset.
    @discardableResult
    func savePreset(name: String, source: String, language: ScriptLanguage = .python) throws -> Preset {
        let sanitized = sanitizeFilename(name)
        guard !sanitized.isEmpty else {
            throw PresetManagerError.invalidName
        }
        let ext = language == .rust ? "rs" : "py"
        let url = presetsURL.appendingPathComponent("\(sanitized).\(ext)")
        try source.write(to: url, atomically: true, encoding: .utf8)
        log.info("Saved user preset: \(sanitized).\(ext, privacy: .public)")

        refreshPresets()

        guard let preset = presets.first(where: { $0.id == "user:\(sanitized).\(ext)" }) else {
            throw PresetManagerError.saveFailed
        }
        onPresetWritten?(preset, nil)
        return preset
    }

    // MARK: - Delete

    /// Delete a user preset. Factory presets cannot be deleted.
    func deletePreset(_ preset: Preset) throws {
        switch preset.source {
        case .factory:
            log.warning("Attempted to delete factory preset: \(preset.name, privacy: .public)")
            return
        case .user(let url):
            try fileManager.removeItem(at: url)
            log.info("Deleted user preset: \(preset.name, privacy: .public)")
            onPresetDeleted?(preset.name, url, preset.language)
        }

        refreshPresets()

        if currentPreset?.id == preset.id {
            currentPreset = nil
            loadedSource = nil
            isModified = false
        }
    }

    /// Backward-compat alias.
    func deleteUserPreset(_ preset: Preset) throws {
        try deletePreset(preset)
    }

    // MARK: - Rename

    /// Rename a user preset. Factory presets cannot be renamed.
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
        switch preset.source {
        case .factory:
            throw PresetManagerError.renameFailed
        case .user(let url):
            oldURL = url
        }

        let ext = preset.fileExtension
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent("\(sanitized).\(ext)")
        try fileManager.moveItem(at: oldURL, to: newURL)
        log.info("Renamed preset: \(preset.name, privacy: .public) → \(sanitized, privacy: .public)")

        refreshPresets()

        let newID = "user:\(sanitized).\(ext)"
        guard let renamedPreset = presets.first(where: { $0.id == newID }) else {
            throw PresetManagerError.renameFailed
        }

        onPresetWritten?(renamedPreset, preset.name)

        // Update current preset reference if it was the renamed one
        if currentPreset?.id == preset.id {
            currentPreset = renamedPreset
        }

        return renamedPreset
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

    /// Check whether a user preset with this name already exists.
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
