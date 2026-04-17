import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PresetManager")

/// Manages discovery, loading, saving, and deletion of DSP script presets.
///
/// Every preset is a `.cdp` bundle directory containing `manifest.json` and
/// an entry script (`process.py` / `process.rs`), plus an optional `ui/`
/// subtree for a custom HTML/JS UI. Factory presets ship under
/// `Resources/presets/preset_*.cdp/` (read-only); user presets live under
/// `<AppGroup>/Presets/`, which is a git repository managed by
/// `PresetGitCoordinator` — save / delete / rename here, the coordinator
/// records a commit.
@MainActor
class PresetManager: ObservableObject {
    @Published private(set) var presets: [Preset] = []
    @Published var currentPreset: Preset?
    @Published var isModified: Bool = false

    /// Parsed bundle view of `currentPreset`. Nil only when `currentPreset`
    /// is nil (factory presets also produce a bundle view, backed by the
    /// read-only extension Resources). Published so the UI can decide
    /// between custom HTML/JS UI and the default slider panel.
    @Published private(set) var currentBundle: PresetBundle?

    /// The script source at the time the current preset was loaded, for modification detection.
    private(set) var loadedSource: String?

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

    /// Extensions recognized by the legacy-flat-file migration pass. Steady
    /// state has zero flat files — this set only catches pre-bundle data
    /// sitting in a user's App Group container from an old install.
    private static let legacyScriptExtensions: Set<String> = ["py", "rs"]

    func refreshPresets() {
        var result: [Preset] = []

        // Factory presets live in the extension's Resources under
        // `presets/preset_*.cdp/`. Registry holds display names + category
        // metadata; PresetBundle.load resolves each bundle lazily.
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

        // User presets from the git-backed Presets/ directory.
        result.append(contentsOf: discoverPresets(in: presetsURL))

        presets = result
    }

    private func discoverPresets(in directory: URL) -> [Preset] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Lazy migration: any pre-bundle `.py` / `.rs` flat file still
        // sitting in `directory` (from before the bundles-only transition)
        // gets wrapped into a `.cdp/` bundle on first read and then deleted.
        // After it runs the steady-state is bundles-only, and this loop
        // becomes a no-op every subsequent launch.
        migrateLegacyFlatFiles(in: entries)

        // Re-enumerate after migration so newly-created `.cdp/` dirs show
        // up without needing a second refreshPresets() call.
        let refreshed = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? entries

        let bundleDirs = refreshed.filter { url in
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return false
            }
            return PresetBundle.looksLikeBundle(at: url)
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }

        var result: [Preset] = []
        for url in bundleDirs {
            guard let bundle = PresetBundle.load(from: url) else {
                log.warning("Skipping malformed bundle at \(url.path, privacy: .public)")
                continue
            }
            let name = bundle.name
            let category: PresetCategory = {
                guard let raw = bundle.manifest.meta?.category else { return .other }
                return PresetCategory(rawValue: raw.lowercased()) ?? .other
            }()
            result.append(Preset(
                id: "user:\(name)",
                name: name,
                source: .user(url: url),
                factoryPresetNumber: nil,
                language: bundle.language,
                category: category,
                descriptionText: bundle.manifest.meta?.description,
                author: bundle.manifest.meta?.author
            ))
        }
        return result
    }

    /// Wrap any pre-bundle `.py` / `.rs` flat files (from before the
    /// bundles-only transition) into `.cdp` bundle directories. Runs as
    /// part of `discoverPresets` so users with pre-bundle data never see
    /// presets disappear — they just become bundles silently on first
    /// load. Subsequent launches find no flat files and this is a no-op.
    private func migrateLegacyFlatFiles(in urls: [URL]) {
        for url in urls where Self.legacyScriptExtensions.contains(url.pathExtension) {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let language: ScriptLanguage = ext == "rs" ? .rust : .python
            let bundleURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem).\(PresetBundle.bundleExtension)", isDirectory: true)

            guard !fileManager.fileExists(atPath: bundleURL.path) else {
                log.warning("Legacy flat file \(url.lastPathComponent, privacy: .public) conflicts with existing bundle; leaving untouched")
                continue
            }

            do {
                try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
                let manifest = PresetBundle.defaultManifest(language: language, includeUI: true)
                try manifest.jsonData().write(to: bundleURL.appendingPathComponent(PresetManifest.filename))
                let scriptURL = bundleURL.appendingPathComponent(manifest.entry)
                try fileManager.moveItem(at: url, to: scriptURL)
                log.info("Migrated legacy preset \(stem, privacy: .public) to bundle")
            } catch {
                log.error("Legacy migration failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Load

    /// Read the entry script source for a preset.
    func loadSource(for preset: Preset) -> String? {
        switch preset.source {
        case .factory(let resourceName):
            guard let bundle = factoryBundle(for: resourceName) else {
                log.error("Factory bundle not found for \(resourceName, privacy: .public)")
                return nil
            }
            return try? bundle.readSource()
        case .user(let url):
            guard let bundle = PresetBundle.load(from: url) else {
                log.error("Bundle failed to load at \(url.path, privacy: .public)")
                return nil
            }
            return try? bundle.readSource()
        }
    }

    /// Load the parsed bundle view for a preset. Returns `nil` if the
    /// bundle is unreadable (malformed manifest, missing entry script).
    /// Factory bundles live under the extension's `Resources/presets/`
    /// and are resolved via `Bundle.url(forResource:withExtension:subdirectory:)`.
    func loadBundle(for preset: Preset) -> PresetBundle? {
        switch preset.source {
        case .factory(let resourceName):
            return factoryBundle(for: resourceName)
        case .user(let url):
            return PresetBundle.load(from: url)
        }
    }

    /// Resolve a factory preset's `.cdp` bundle inside the extension's
    /// Resources. Cached on first hit because Bundle URL lookup isn't
    /// cheap and factory presets load repeatedly (preset cycling in the
    /// browser, DAW preset menu queries, etc.).
    private func factoryBundle(for resourceName: String) -> PresetBundle? {
        if let cached = factoryBundleCache[resourceName] { return cached }
        guard let bundleURL = extensionBundle.url(
            forResource: resourceName,
            withExtension: PresetBundle.bundleExtension,
            subdirectory: "presets"
        ) else { return nil }
        guard let bundle = PresetBundle.load(from: bundleURL) else { return nil }
        factoryBundleCache[resourceName] = bundle
        return bundle
    }

    private var factoryBundleCache: [String: PresetBundle] = [:]

    /// Mark a preset as the currently active one and record its source for
    /// modification detection.
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

    // MARK: - Save

    /// Save `source` as a user preset bundle. Creates `<sanitized>.cdp/`
    /// under `presetsURL` with a default manifest + entry script. When
    /// `scaffoldUI == true` and the bundle doesn't already exist, also
    /// writes a starter `ui/index.html` with one slider per parameter.
    ///
    /// Re-saving an existing preset preserves any `ui/` contents the user
    /// already authored — we capture the subtree, rewrite the bundle, and
    /// restore ui files. The scaffold flag is a no-op in that case (the
    /// user already has a UI to keep).
    @discardableResult
    func savePreset(
        name: String,
        source: String,
        language: ScriptLanguage = .python,
        scaffoldUI: Bool = false
    ) throws -> Preset {
        let sanitized = sanitizeFilename(name)
        guard !sanitized.isEmpty else {
            throw PresetManagerError.invalidName
        }

        let bundleURL = presetsURL.appendingPathComponent(
            "\(sanitized).\(PresetBundle.bundleExtension)", isDirectory: true
        )

        // If the bundle already exists, capture any `ui/` subtree so the
        // rewrite doesn't clobber author-visible HTML/CSS/JS.
        var preservedUIContents: [(URL, Data)] = []
        if fileManager.fileExists(atPath: bundleURL.path) {
            let uiDir = bundleURL.appendingPathComponent("ui", isDirectory: true)
            if let walker = fileManager.enumerator(
                at: uiDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in walker {
                    let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                    guard isRegular, let data = try? Data(contentsOf: url) else { continue }
                    preservedUIContents.append((url, data))
                }
            }
            try fileManager.removeItem(at: bundleURL)
        }

        try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = PresetBundle.defaultManifest(language: language, includeUI: true)
        try manifest.jsonData().write(to: bundleURL.appendingPathComponent(PresetManifest.filename))

        let scriptURL = bundleURL.appendingPathComponent(manifest.entry)
        try source.write(to: scriptURL, atomically: true, encoding: .utf8)

        // Restore preserved UI files first; if nothing was preserved and
        // the caller asked for a scaffold, drop in the starter index.html.
        if !preservedUIContents.isEmpty {
            for (originalURL, data) in preservedUIContents {
                try fileManager.createDirectory(
                    at: originalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: originalURL, options: .atomic)
            }
        } else if scaffoldUI {
            let uiDir = bundleURL.appendingPathComponent("ui", isDirectory: true)
            try fileManager.createDirectory(at: uiDir, withIntermediateDirectories: true)
            try PresetBundle.starterIndexHTML().write(
                to: uiDir.appendingPathComponent("index.html"),
                atomically: true,
                encoding: .utf8
            )
        }

        log.info("Saved user bundle: \(bundleURL.path, privacy: .public)")
        refreshPresets()

        guard let preset = presets.first(where: { $0.id == "user:\(sanitized)" }) else {
            throw PresetManagerError.saveFailed
        }
        return preset
    }

    // MARK: - Delete

    /// Delete a user preset. Factory presets cannot be deleted.
    /// Bundle directories remove cleanly through `removeItem`.
    func deletePreset(_ preset: Preset) throws {
        switch preset.source {
        case .factory:
            log.warning("Attempted to delete factory preset: \(preset.name, privacy: .public)")
            return
        case .user(let url):
            try fileManager.removeItem(at: url)
            log.info("Deleted user bundle: \(preset.name, privacy: .public)")
        }

        refreshPresets()

        if currentPreset?.id == preset.id {
            currentPreset = nil
            currentBundle = nil
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

        // Preserve the `.cdp` suffix if present (every bundle ConjureDSP
        // creates has it; user-dropped bundles may not).
        let oldLast = oldURL.lastPathComponent
        let suffix = oldLast.hasSuffix(".\(PresetBundle.bundleExtension)") ? ".\(PresetBundle.bundleExtension)" : ""
        let newURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent("\(sanitized)\(suffix)")
        try fileManager.moveItem(at: oldURL, to: newURL)
        log.info("Renamed bundle: \(preset.name, privacy: .public) → \(sanitized, privacy: .public)")

        refreshPresets()

        let newID = "user:\(sanitized)"
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
