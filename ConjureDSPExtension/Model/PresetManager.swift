import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PresetManager")

/// Manages discovery, loading, saving, and deletion of DSP script presets.
///
/// Factory presets are read from the extension bundle (read-only).
/// User presets are stored as .py/.rs files in the App Group container under Presets/.
/// Repo presets are cached locally under RepoPresets/ and synced to GitHub.
@MainActor
class PresetManager: ObservableObject {
    @Published private(set) var presets: [Preset] = []
    @Published var currentPreset: Preset?
    @Published var isModified: Bool = false

    /// Parsed bundle view of `currentPreset` when it is a bundle preset. Nil
    /// for factory and legacy single-file presets. Published so the UI can
    /// observe and decide between custom HTML/JS UI and the default sliders.
    @Published private(set) var currentBundle: PresetBundle?

    /// The script source at the time the current preset was loaded, for modification detection.
    private(set) var loadedSource: String?

    /// Called after a repo preset is saved. GitHubService hooks into this to trigger background push.
    var onRepoPresetSaved: ((String, String, ScriptLanguage) -> Void)?

    /// Called after a repo preset is deleted. GitHubService hooks into this to trigger background delete.
    var onRepoPresetDeleted: ((String, ScriptLanguage) -> Void)?

    /// Called after a repo preset is renamed. Parameters: (oldName, newName, source, language).
    var onRepoPresetRenamed: ((String, String, String, ScriptLanguage) -> Void)?

    /// Called after a repo bundle is saved (new or updated). GitHubService
    /// hooks into this to push the whole `<name>.cdp/` directory tree to
    /// `bundles/<name>/` in the remote repo. The URL points at the local
    /// bundle root so the sync code can walk the directory.
    var onRepoBundleSaved: ((String, URL) -> Void)?

    /// Called after a repo bundle is deleted. Argument is the bundle's
    /// sanitized name (same as the directory stem without `.cdp`).
    var onRepoBundleDeleted: ((String) -> Void)?

    /// Called after a repo bundle is renamed. Arguments: (oldName, newName,
    /// newBundleURL). The sync layer uses this to push the new directory
    /// and delete the old one under `bundles/<oldName>/`.
    var onRepoBundleRenamed: ((String, String, URL) -> Void)?

    private let extensionBundle: Bundle
    let userPresetsURL: URL
    let repoPresetsURL: URL
    private let fileManager = FileManager.default

    init(extensionBundle: Bundle) {
        self.extensionBundle = extensionBundle

        let baseDir = AppGroupContainer.url
        self.userPresetsURL = baseDir.appendingPathComponent("Presets", isDirectory: true)
        self.repoPresetsURL = baseDir.appendingPathComponent("RepoPresets", isDirectory: true)

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
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [Preset] = []

        // Directories containing manifest.json → bundle presets.
        let bundleDirs = entries.filter { url in
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
            return PresetBundle.looksLikeBundle(at: url)
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        for url in bundleDirs {
            guard let bundle = PresetBundle.load(from: url) else {
                log.warning("Skipping malformed bundle at \(url.path, privacy: .public)")
                continue
            }
            let name = bundle.name
            let source: Preset.Source = prefix == "repo" ? .repoBundle(url: url) : .userBundle(url: url)
            let category: PresetCategory = {
                guard let raw = bundle.manifest.meta?.category else { return .other }
                return PresetCategory(rawValue: raw.lowercased()) ?? .other
            }()
            result.append(Preset(
                id: "\(prefix):bundle:\(name)",
                name: name,
                source: source,
                factoryPresetNumber: nil,
                language: bundle.language,
                category: category,
                descriptionText: bundle.manifest.meta?.description,
                author: bundle.manifest.meta?.author
            ))
        }

        // Top-level `.py` / `.rs` files → legacy single-file presets.
        let scriptFiles = entries
            .filter { Self.supportedExtensions.contains($0.pathExtension) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        for url in scriptFiles {
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let language: ScriptLanguage = ext == "rs" ? .rust : .python
            let source: Preset.Source = prefix == "repo" ? .repo(url: url) : .user(url: url)
            result.append(Preset(
                id: "\(prefix):\(name).\(ext)",
                name: name,
                source: source,
                factoryPresetNumber: nil,
                language: language,
                category: .other
            ))
        }

        return result
    }

    // MARK: - Load

    /// Read the source code for a preset.
    func loadSource(for preset: Preset) -> String? {
        switch preset.source {
        case .factory(let resourceName):
            // Factory presets ship as `.cdp` bundle directories inside the
            // extension's Resources. Load the bundle and read its entry
            // script. This path replaced the flat `preset_*.{py,rs}` layout
            // when factory presets were converted to bundles so the editor
            // can treat them identically to user/repo bundles.
            guard let bundle = factoryBundle(for: resourceName) else {
                log.error("Factory bundle not found for \(resourceName, privacy: .public)")
                return nil
            }
            return try? bundle.readSource()
        case .user(let url), .repo(let url):
            return try? String(contentsOf: url, encoding: .utf8)
        case .userBundle(let url), .repoBundle(let url):
            guard let bundle = PresetBundle.load(from: url) else {
                log.error("Bundle preset failed to load at \(url.path, privacy: .public)")
                return nil
            }
            return try? bundle.readSource()
        }
    }

    /// Load the parsed bundle view for a preset, or nil if the preset is not
    /// a bundle. Factory presets also return a bundle now (they ship as
    /// `.cdp` directories in the extension's Resources) so the UI layer can
    /// treat factory and user/repo bundles uniformly — both have a
    /// manifest, both can opt into a custom HTML/JS UI.
    func loadBundle(for preset: Preset) -> PresetBundle? {
        if case .factory(let resourceName) = preset.source {
            return factoryBundle(for: resourceName)
        }
        guard let url = preset.bundleURL else { return nil }
        return PresetBundle.load(from: url)
    }

    /// Resolve a factory preset's `.cdp` bundle inside the extension's
    /// Resources. Cached on first hit because Bundle URL lookup isn't
    /// cheap and factory presets are loaded repeatedly (cycling in the
    /// browser, DAW preset list queries, etc.).
    private func factoryBundle(for resourceName: String) -> PresetBundle? {
        if let cached = factoryBundleCache[resourceName] { return cached }
        // Factory bundles live under `Resources/presets/` — checked into the
        // repo as `.cdp/` directories and shipped verbatim by Xcode via the
        // synchronized group's `explicitFolders = ("Resources/presets")`.
        // Without the `subdirectory:` arg, Bundle.url won't find them.
        guard let bundleURL = extensionBundle.url(
            forResource: resourceName,
            withExtension: PresetBundle.bundleExtension,
            subdirectory: "presets"
        ) else { return nil }
        guard let bundle = PresetBundle.load(from: bundleURL) else { return nil }
        factoryBundleCache[resourceName] = bundle
        return bundle
    }

    /// Memoized factory-bundle lookups keyed by `resourceName`.
    private var factoryBundleCache: [String: PresetBundle] = [:]

    /// Mark a preset as the currently active one and record its source for modification detection.
    func setCurrentPreset(_ preset: Preset?, source: String?) {
        currentPreset = preset
        loadedSource = source
        isModified = false
        currentBundle = preset.flatMap { loadBundle(for: $0) }
    }

    /// Call when the user edits the script to update the modified flag.
    func scriptDidChange(to newSource: String) {
        guard let loaded = loadedSource else {
            isModified = true
            return
        }
        isModified = (newSource != loaded)
    }

    // NOTE: Single-file `saveUserPreset` / `saveRepoPreset` were removed when
    // the preset format moved to directory bundles. Legacy single-file presets
    // still LOAD (via `discoverPresets`) for backward compatibility with
    // pre-bundle user data, but all new saves go through `saveUserBundle` /
    // `saveRepoBundle` below.

    // MARK: - Delete

    /// Delete a user or repo preset. Factory presets cannot be deleted.
    /// Bundles are removed as a whole directory; `FileManager.removeItem` handles
    /// both files and directories.
    func deletePreset(_ preset: Preset) throws {
        switch preset.source {
        case .factory:
            log.warning("Attempted to delete factory preset: \(preset.name, privacy: .public)")
            return
        case .user(let url), .userBundle(let url):
            try fileManager.removeItem(at: url)
            log.info("Deleted user preset: \(preset.name, privacy: .public)")
        case .repo(let url):
            try fileManager.removeItem(at: url)
            log.info("Deleted repo preset: \(preset.name, privacy: .public)")
            onRepoPresetDeleted?(preset.name, preset.language)
        case .repoBundle(let url):
            try fileManager.removeItem(at: url)
            log.info("Deleted repo bundle: \(preset.name, privacy: .public)")
            // Bundles go through a separate delete callback so the sync
            // layer can enumerate + remove every file under `bundles/<name>/`
            // on the remote, instead of single-file removal.
            let sanitized = sanitizeFilename(preset.name)
            onRepoBundleDeleted?(sanitized)
        }

        refreshPresets()

        if currentPreset?.id == preset.id {
            currentPreset = nil
            currentBundle = nil
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
        let isBundle: Bool
        switch preset.source {
        case .factory:
            throw PresetManagerError.renameFailed
        case .user(let url):
            oldURL = url; prefix = "user"; isBundle = false
        case .repo(let url):
            oldURL = url; prefix = "repo"; isBundle = false
        case .userBundle(let url):
            oldURL = url; prefix = "user"; isBundle = true
        case .repoBundle(let url):
            oldURL = url; prefix = "repo"; isBundle = true
        }

        let newURL: URL
        if isBundle {
            // Preserve the `.cdp` suffix if the bundle dir used one.
            let oldLast = oldURL.lastPathComponent
            let suffix = oldLast.hasSuffix(".\(PresetBundle.bundleExtension)") ? ".\(PresetBundle.bundleExtension)" : ""
            newURL = oldURL.deletingLastPathComponent().appendingPathComponent("\(sanitized)\(suffix)")
        } else {
            let ext = preset.fileExtension
            newURL = oldURL.deletingLastPathComponent().appendingPathComponent("\(sanitized).\(ext)")
        }
        try fileManager.moveItem(at: oldURL, to: newURL)
        log.info("Renamed preset: \(preset.name, privacy: .public) → \(sanitized, privacy: .public)")

        // For repo presets, trigger background rename on GitHub. Legacy
        // single-file presets go through the source-carrying callback;
        // bundles go through a directory-level callback so the sync code
        // can push the whole `bundles/<newName>/` tree and delete
        // `bundles/<oldName>/`.
        switch preset.source {
        case .repo:
            if let source = try? String(contentsOf: newURL, encoding: .utf8) {
                onRepoPresetRenamed?(preset.name, sanitized, source, preset.language)
            }
        case .repoBundle:
            onRepoBundleRenamed?(preset.name, sanitized, newURL)
        default:
            break
        }

        refreshPresets()

        let newID: String
        if isBundle {
            newID = "\(prefix):bundle:\(sanitized)"
        } else {
            newID = "\(prefix):\(sanitized).\(preset.fileExtension)"
        }
        guard let renamedPreset = presets.first(where: { $0.id == newID }) else {
            throw PresetManagerError.renameFailed
        }

        // Update current preset reference if it was the renamed one. Don't
        // route through `setCurrentPreset` — that resets `isModified` and
        // `loadedSource`, which should survive a rename.
        if currentPreset?.id == preset.id {
            currentPreset = renamedPreset
            currentBundle = loadBundle(for: renamedPreset)
        }

        return renamedPreset
    }

    // MARK: - Migration

    /// Move a user preset to the repo cache. Returns the new repo Preset.
    /// Set `triggerSync: false` when the caller has already pushed to GitHub (e.g. during migration).
    @discardableResult
    func migrateUserPresetToRepo(_ preset: Preset, triggerSync: Bool = true) throws -> Preset {
        let sourceURL: URL
        let isBundle: Bool
        switch preset.source {
        case .user(let url):
            sourceURL = url; isBundle = false
        case .userBundle(let url):
            sourceURL = url; isBundle = true
        default:
            throw PresetManagerError.saveFailed
        }
        let destURL = repoPresetsURL.appendingPathComponent(sourceURL.lastPathComponent)
        try fileManager.moveItem(at: sourceURL, to: destURL)
        log.info("Migrated preset to repo: \(preset.name, privacy: .public)")

        if triggerSync {
            if isBundle {
                onRepoBundleSaved?(sanitizeFilename(preset.name), destURL)
            } else if let source = try? String(contentsOf: destURL, encoding: .utf8) {
                onRepoPresetSaved?(preset.name, source, preset.language)
            }
        }

        refreshPresets()

        let expectedID = isBundle
            ? "repo:bundle:\(preset.name)"
            : "repo:\(preset.name).\(preset.fileExtension)"
        return presets.first(where: { $0.id == expectedID }) ?? preset
    }

    // MARK: - Bundle creation

    /// Save a preset as a bundle directory. Creates
    /// `<rootDir>/<name>.cdp/` containing `manifest.json` (with a `ui` block
    /// advertising `ui/index.html`) and the entry script. Overwrites any
    /// existing bundle at the same location.
    ///
    /// The `ui` block is always written so that authors can activate a custom
    /// UI later by dropping an `ui/index.html` file into the bundle — the
    /// plugin picks it up on next load without any further manifest edits.
    ///
    /// `scaffoldUI: true` additionally writes a starter `ui/index.html` that
    /// binds `window.ConjureDSP.parameters` to one slider per parameter.
    @discardableResult
    func saveUserBundle(
        name: String,
        source: String,
        language: ScriptLanguage = .python,
        scaffoldUI: Bool = false
    ) throws -> Preset {
        try writeBundle(rootDir: userPresetsURL, name: name, source: source, language: language, scaffoldUI: scaffoldUI)
        let sanitized = sanitizeFilename(name)
        guard let preset = presets.first(where: { $0.id == "user:bundle:\(sanitized)" }) else {
            throw PresetManagerError.saveFailed
        }
        return preset
    }

    /// Save a preset as a bundle in the repo cache. Fires
    /// `onRepoBundleSaved(sanitizedName, bundleURL)` so GitHubService can
    /// push the directory tree to `bundles/<name>/` on the remote.
    @discardableResult
    func saveRepoBundle(
        name: String,
        source: String,
        language: ScriptLanguage = .python,
        scaffoldUI: Bool = false
    ) throws -> Preset {
        try writeBundle(rootDir: repoPresetsURL, name: name, source: source, language: language, scaffoldUI: scaffoldUI)
        let sanitized = sanitizeFilename(name)
        guard let preset = presets.first(where: { $0.id == "repo:bundle:\(sanitized)" }) else {
            throw PresetManagerError.saveFailed
        }
        let bundleURL = repoPresetsURL.appendingPathComponent(
            "\(sanitized).\(PresetBundle.bundleExtension)", isDirectory: true
        )
        onRepoBundleSaved?(sanitized, bundleURL)
        return preset
    }

    /// Internal helper: write a bundle directory at `rootDir/<name>.cdp/`.
    private func writeBundle(
        rootDir: URL,
        name: String,
        source: String,
        language: ScriptLanguage,
        scaffoldUI: Bool
    ) throws {
        let sanitized = sanitizeFilename(name)
        guard !sanitized.isEmpty else { throw PresetManagerError.invalidName }

        let bundleURL = rootDir.appendingPathComponent("\(sanitized).\(PresetBundle.bundleExtension)", isDirectory: true)

        // Fresh directory — remove any stale bundle at the same path.
        if fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.removeItem(at: bundleURL)
        }
        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Always include the `ui` manifest block; whether a UI actually
        // renders is decided by the presence of `ui/index.html`.
        let manifest = PresetBundle.defaultManifest(language: language, includeUI: true)
        try manifest.jsonData().write(to: bundleURL.appendingPathComponent(PresetManifest.filename))

        let scriptURL = bundleURL.appendingPathComponent(manifest.entry)
        try source.write(to: scriptURL, atomically: true, encoding: .utf8)

        if scaffoldUI {
            let uiDir = bundleURL.appendingPathComponent("ui", isDirectory: true)
            try fileManager.createDirectory(at: uiDir, withIntermediateDirectories: true)
            try PresetBundle.starterIndexHTML().write(
                to: uiDir.appendingPathComponent("index.html"),
                atomically: true,
                encoding: .utf8
            )
        }

        log.info("Saved bundle: \(bundleURL.path, privacy: .public)")
        refreshPresets()
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
