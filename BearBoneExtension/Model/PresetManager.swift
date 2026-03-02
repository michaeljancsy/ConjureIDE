import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "PresetManager")

/// Manages discovery, loading, saving, and deletion of Python DSP script presets.
///
/// Factory presets are read from the extension bundle (read-only).
/// User presets are stored as .py files in ~/Library/Application Support/BearBone/Presets/.
@MainActor
class PresetManager: ObservableObject {
    @Published private(set) var presets: [Preset] = []
    @Published var currentPreset: Preset?
    @Published var isModified: Bool = false

    /// The script source at the time the current preset was loaded, for modification detection.
    private(set) var loadedSource: String?

    private let extensionBundle: Bundle
    let userPresetsURL: URL
    private let fileManager = FileManager.default

    init(extensionBundle: Bundle) {
        self.extensionBundle = extensionBundle

        let appSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.userPresetsURL = appSupport
            .appendingPathComponent("BearBone", isDirectory: true)
            .appendingPathComponent("Presets", isDirectory: true)

        ensureUserPresetsDirectory()
        refreshPresets()
    }

    /// Testable initializer that accepts an explicit user presets URL.
    init(extensionBundle: Bundle, userPresetsURL: URL) {
        self.extensionBundle = extensionBundle
        self.userPresetsURL = userPresetsURL

        ensureUserPresetsDirectory()
        refreshPresets()
    }

    // MARK: - Directory Management

    private func ensureUserPresetsDirectory() {
        guard !fileManager.fileExists(atPath: userPresetsURL.path) else { return }
        do {
            try fileManager.createDirectory(at: userPresetsURL, withIntermediateDirectories: true)
            log.info("Created user presets directory: \(self.userPresetsURL.path, privacy: .public)")
        } catch {
            log.error("Failed to create user presets directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Preset Discovery

    func refreshPresets() {
        var result: [Preset] = []

        // Factory presets from bundle
        for entry in FactoryPresetRegistry.entries {
            result.append(Preset(
                id: "factory:\(entry.name)",
                name: entry.name,
                source: .factory(resourceName: entry.resourceName),
                factoryPresetNumber: entry.number
            ))
        }

        // User presets from disk
        if let files = try? fileManager.contentsOfDirectory(
            at: userPresetsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let pyFiles = files
                .filter { $0.pathExtension == "py" }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

            for url in pyFiles {
                let name = url.deletingPathExtension().lastPathComponent
                result.append(Preset(
                    id: "user:\(name)",
                    name: name,
                    source: .user(url: url),
                    factoryPresetNumber: nil
                ))
            }
        }

        presets = result
    }

    // MARK: - Load

    /// Read the Python source for a preset.
    func loadSource(for preset: Preset) -> String? {
        switch preset.source {
        case .factory(let resourceName):
            guard let url = extensionBundle.url(forResource: resourceName, withExtension: "py") else {
                log.error("Factory preset resource not found: \(resourceName, privacy: .public)")
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
    func saveUserPreset(name: String, source: String) throws -> Preset {
        let sanitized = sanitizeFilename(name)
        guard !sanitized.isEmpty else {
            throw PresetManagerError.invalidName
        }
        let url = userPresetsURL.appendingPathComponent("\(sanitized).py")
        try source.write(to: url, atomically: true, encoding: .utf8)
        log.info("Saved user preset: \(sanitized, privacy: .public)")

        refreshPresets()

        guard let preset = presets.first(where: { $0.id == "user:\(sanitized)" }) else {
            throw PresetManagerError.saveFailed
        }
        return preset
    }

    // MARK: - Delete

    /// Delete a user preset. Factory presets cannot be deleted.
    func deleteUserPreset(_ preset: Preset) throws {
        guard case .user(let url) = preset.source else {
            log.warning("Attempted to delete factory preset: \(preset.name, privacy: .public)")
            return
        }
        try fileManager.removeItem(at: url)
        log.info("Deleted user preset: \(preset.name, privacy: .public)")

        refreshPresets()

        if currentPreset?.id == preset.id {
            currentPreset = nil
            loadedSource = nil
            isModified = false
        }
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
        return presets.contains { $0.id == "user:\(sanitized)" }
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

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Preset name is invalid"
        case .saveFailed: return "Failed to save preset"
        }
    }
}
