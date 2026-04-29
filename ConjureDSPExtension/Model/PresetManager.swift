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

    /// URLs of bundle files that have been written to disk via the in-plugin
    /// editor's debounce path (manifest.json, ui/**) but haven't been
    /// committed yet. Populated by the main view's `scheduleAltFileSave`,
    /// cleared on explicit Save (commit) or preset switch.
    ///
    /// The entry script isn't tracked here — it uses `isModified` (in-memory
    /// diff against `loadedSource`) because the editor buffer is still
    /// considered "the truth" until Run/Save; debounced writes to disk
    /// don't happen for the entry script.
    @Published private(set) var dirtyFiles: Set<URL> = []

    /// True when *anything* about the current preset has user-visible
    /// uncommitted state — either the entry-script buffer differs from the
    /// on-disk loaded source, or the debounced writer has landed ui/manifest
    /// edits that haven't been committed. Drives the Save button's
    /// enabled state so editing `ui/index.html` alone is still "savable."
    var hasPendingChanges: Bool { isModified || !dirtyFiles.isEmpty }

    /// The script source at the time the current preset was loaded, for modification detection.
    private(set) var loadedSource: String?

    private let extensionBundle: Bundle
    let presetsURL: URL
    private let fileManager = FileManager.default

    /// Watches the active *user* bundle's root directory for filesystem
    /// changes made outside the in-plugin flows (VS Code, Finder, `git
    /// checkout`, terminal `mv`, etc.) so `currentBundle` reflects the
    /// on-disk truth without waiting for the next preset switch / save /
    /// MCP write. Nil when the active preset is factory (read-only) or
    /// nil. Owned here rather than at the view layer because the view
    /// (`CustomUIWebView`) only exists once the bundle already has a UI;
    /// this watcher is what lets a UI *appear* in the toolbar at all when
    /// it's added externally.
    private var bundleWatcher: BundleFileWatcher?

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
            // Strip the quarantine xattr macOS 26 sets on new sandboxed-appex
            // writes — without this, a future build with a different
            // signing identity gets denied when it tries to write into
            // this directory. See AppGroupContainer.stripQuarantine docs.
            AppGroupContainer.stripQuarantine(at: url)
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

        // Re-parse the currently active bundle from disk so observers see
        // manifest.json / ui/ edits made via the file browser. Without
        // this, currentBundle holds a stale PresetBundle captured at
        // setCurrentPreset time, and the custom-UI frame keeps rendering
        // yesterday's height even after the user edits the manifest.
        if let current = currentPreset {
            currentBundle = loadBundle(for: current)
        }
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
            switch PresetBundle.loadResult(from: url) {
            case .ok(let bundle):
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
            case .broken(let name, let rootURL, let error):
                // Surface broken bundles in the list with an error string
                // so the browser can render them with a warning glyph and
                // the user has a starting point for diagnosis. Without
                // this, a hand-edited manifest with a typo (e.g. invalid
                // JSON like `"height": 00`) makes the preset silently
                // vanish from the list with no signal anywhere about why.
                log.error("Broken bundle at \(rootURL.path, privacy: .public): \(error, privacy: .public)")
                result.append(Preset(
                    id: "user:\(name)",
                    name: name,
                    source: .user(url: rootURL),
                    factoryPresetNumber: nil,
                    language: .python, // best-effort guess — manifest is unparsable
                    category: .other,
                    brokenError: error
                ))
            case .notABundle:
                continue
            }
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
                // Legacy flat-file migration wraps an existing .py/.rs — no
                // custom UI is being introduced, so don't emit a manifest
                // ui block that points at a nonexistent ui/index.html.
                let manifest = PresetBundle.defaultManifest(language: language, includeUI: false)
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

    /// Set a broken preset as the current one for repair (manifest editing).
    /// Skips the DSP load pipeline — `currentBundle` is populated via
    /// `PresetBundle.inspect` so the file picker can list `manifest.json`
    /// and other bundle files, but `loadedSource` stays nil and the kernel
    /// is not touched. Audio remains passthrough until the user fixes the
    /// manifest and the bundle re-parses cleanly via `refreshPresets`.
    func setBrokenPresetForRepair(_ preset: Preset) {
        guard preset.isBroken, case .user(let url) = preset.source else {
            log.warning("setBrokenPresetForRepair called with non-broken preset: \(preset.name, privacy: .public)")
            return
        }
        currentPreset = preset
        loadedSource = nil
        isModified = false
        dirtyFiles.removeAll()
        currentBundle = PresetBundle.inspect(from: url)
        log.info("Loaded broken bundle for repair: \(preset.name, privacy: .public)")
    }

    /// Mark a preset as the currently active one and record its source for
    /// modification detection.
    func setCurrentPreset(_ preset: Preset?, source: String?) {
        currentPreset = preset
        loadedSource = source
        isModified = false
        // Switching presets wipes the dirty set — any uncommitted ui/manifest
        // edits to the previous bundle are still on disk (they survive in
        // the working tree), they just stop being tracked as "the current
        // bundle's pending work."
        dirtyFiles.removeAll()
        currentBundle = preset.flatMap { loadBundle(for: $0) }
        startBundleWatcher(for: preset)
    }

    /// Stop any existing bundle watcher and, if `preset` is a user bundle,
    /// start a new one keyed on its root URL. Factory bundles are skipped
    /// because the appex Resources directory isn't writable at runtime.
    private func startBundleWatcher(for preset: Preset?) {
        bundleWatcher?.stop()
        bundleWatcher = nil

        guard let preset, !preset.isFactory, let rootURL = preset.fileURL else {
            return
        }

        let watcher = BundleFileWatcher(path: rootURL.path)
        watcher.onChange = { [weak self] in
            // FSEventStream callback is dispatched on `.main`; PresetManager
            // is @MainActor, so hop with assumeIsolated to satisfy the
            // isolation checker without an extra async hop.
            MainActor.assumeIsolated {
                self?.refreshPresets()
            }
        }
        watcher.start(on: .main, latency: 0.2)
        bundleWatcher = watcher
    }

    /// Call when the user edits the script to update the modified flag.
    func scriptDidChange(to newSource: String) {
        guard let loaded = loadedSource else {
            isModified = true
            return
        }
        isModified = (newSource != loaded)
    }

    /// The disk-truth equivalent of `setCurrentPreset(_:source:)` for
    /// out-of-band writes that land an entry-script payload directly to
    /// disk (MCP `write_bundle_file`). Without this, the typical agent
    /// flow — `write_bundle_file('process.py', NEW)` followed by
    /// `compile_and_run(NEW)` — leaves `loadedSource` set to the OLD
    /// content from the bundle's prior load. The downstream
    /// `scriptSourceDidChange` echo from `compile_and_run` then drives
    /// `scriptDidChange(NEW)`, which compares NEW to the stale
    /// `loadedSource` (OLD) and flips `isModified = true` even though
    /// kernel and disk are perfectly in sync. Updating `loadedSource`
    /// here makes the comparison a no-op and keeps the dirty flag
    /// honest. `selectPreset` / `save_preset` don't need an analogous
    /// call because they go through `setCurrentPreset` first.
    func markEntryScriptSaved(_ content: String) {
        loadedSource = content
        isModified = false
    }

    /// Record that the debounced editor has written `url` to disk. The main
    /// view calls this after each successful `scheduleAltFileSave` write so
    /// the UI can reflect "save available" without requiring a commit.
    func noteDirtyFile(_ url: URL) {
        dirtyFiles.insert(url)
    }

    /// Clear the dirty set — called by the save flow after a successful
    /// commit so the Save button disables until the next edit.
    func clearDirtyFiles() {
        dirtyFiles.removeAll()
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
    ///
    /// `duplicateFrom`, when non-nil and the target doesn't already exist,
    /// makes Save-As behave like "fork this bundle under a new name":
    /// copy the entire source bundle tree (manifest.json, manifest.params,
    /// `ui/` and any assets), then overwrite the entry script with `source`.
    /// `scaffoldUI` is ignored on this path — the source bundle's UI tree
    /// (or absence of one) is preserved verbatim. When the caller-supplied
    /// `language` differs from the source bundle's language, the manifest's
    /// `entry`/`language` are patched and the old entry script is removed
    /// so the duplicate compiles cleanly in the new language.
    ///
    /// Without `duplicateFrom`, a fresh bundle is built from a default
    /// manifest. Callers that need to clone content from another preset
    /// should pass `duplicateFrom`; otherwise the new bundle starts blank.
    /// Keeping save_preset minimal avoids the manifest-vs-source
    /// mismatch that auto-cloning a factory bundle used to produce when
    /// the new source declared different params.
    @discardableResult
    func savePreset(
        name: String,
        source: String,
        language: ScriptLanguage = .python,
        scaffoldUI: Bool = false,
        duplicateFrom: PresetBundle? = nil
    ) throws -> Preset {
        let sanitized = sanitizeFilename(name)
        guard !sanitized.isEmpty else {
            throw PresetManagerError.invalidName
        }

        let bundleURL = presetsURL.appendingPathComponent(
            "\(sanitized).\(PresetBundle.bundleExtension)", isDirectory: true
        )

        let bundleExists = fileManager.fileExists(atPath: bundleURL.path)

        // Three branches:
        //
        //  1. Target bundle already exists → re-save. Preserve manifest
        //     and ui/; overwrite entry script only.
        //  2. Target doesn't exist + duplicateFrom is set → Save As fork:
        //     tree-copy the source bundle (manifest, ui/, assets), then
        //     overwrite the entry script.
        //  3. Target doesn't exist + no source bundle → fresh bundle
        //     with default manifest + script + optional starter UI.
        if bundleExists {
            let manifestURL = bundleURL.appendingPathComponent(PresetManifest.filename)
            let existingManifest: PresetManifest? = {
                guard let data = try? Data(contentsOf: manifestURL) else { return nil }
                return try? JSONDecoder().decode(PresetManifest.self, from: data)
            }()
            // If we can't parse the existing manifest, fall back to the
            // defaults — a broken manifest is worse than losing user edits.
            let manifest = existingManifest
                ?? PresetBundle.defaultManifest(language: language, includeUI: scaffoldUI)

            // Write the entry script according to whatever the manifest
            // says its entry path is — respects user edits to `entry` too.
            let scriptURL = bundleURL.appendingPathComponent(manifest.entry)
            try source.write(to: scriptURL, atomically: true, encoding: .utf8)
            AppGroupContainer.stripQuarantine(at: scriptURL)

            // If the existing manifest didn't round-trip (corrupt file),
            // rewrite it with the fallback so subsequent reads succeed.
            if existingManifest == nil {
                try manifest.jsonData().write(to: manifestURL)
                AppGroupContainer.stripQuarantine(at: manifestURL)
            }

            // scaffoldUI on an existing bundle adds `ui/index.html` if
            // the bundle doesn't already ship one. Respects the "+ Add
            // Custom UI" contract. New code paths use `scaffoldCustomUI`
            // directly; this handles older call sites that pass the flag.
            let uiIndexURL = bundleURL.appendingPathComponent("ui/index.html")
            if scaffoldUI, !fileManager.fileExists(atPath: uiIndexURL.path) {
                let uiDir = bundleURL.appendingPathComponent("ui", isDirectory: true)
                try fileManager.createDirectory(at: uiDir, withIntermediateDirectories: true)
                try PresetBundle.starterIndexHTML().write(
                    to: uiIndexURL,
                    atomically: true,
                    encoding: .utf8
                )
                AppGroupContainer.stripQuarantine(at: uiIndexURL)
            }

            log.info("Updated user bundle (preserved manifest): \(bundleURL.path, privacy: .public)")
        } else if let src = duplicateFrom {
            // Save As → fork the source bundle. Tree-copy preserves
            // ui/, manifest.params, and any author assets; the entry
            // script is then overwritten with the editor's source so
            // the duplicate reflects whatever the user has edited
            // since loading the source preset.
            try copyBundleTree(from: src.rootURL, to: bundleURL)

            // If the user is saving in a different language than the
            // source bundle declares (e.g. Save-As'ing a Rust preset
            // with a Python source typed in the editor), patch the
            // manifest and remove the now-stale entry script so the
            // duplicate compiles cleanly. Same-language Save As leaves
            // the manifest untouched.
            let manifestURL = bundleURL.appendingPathComponent(PresetManifest.filename)
            var manifest = src.manifest
            if src.language != language {
                let oldEntryURL = bundleURL.appendingPathComponent(manifest.entry)
                try? fileManager.removeItem(at: oldEntryURL)
                manifest.entry = language == .rust ? "process.rs" : "process.py"
                manifest.language = language.rawValue
                try manifest.jsonData().write(to: manifestURL)
                AppGroupContainer.stripQuarantine(at: manifestURL)
            }

            let scriptURL = bundleURL.appendingPathComponent(manifest.entry)
            try source.write(to: scriptURL, atomically: true, encoding: .utf8)
            AppGroupContainer.stripQuarantine(at: scriptURL)

            log.info("Duplicated user bundle from \(src.rootURL.path, privacy: .public) → \(bundleURL.path, privacy: .public)")
        } else {
            try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            AppGroupContainer.stripQuarantine(at: bundleURL)

            let manifest = PresetBundle.defaultManifest(language: language, includeUI: scaffoldUI)
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

            log.info("Saved new user bundle: \(bundleURL.path, privacy: .public)")
        }

        refreshPresets()

        guard let preset = presets.first(where: { $0.id == "user:\(sanitized)" }) else {
            throw PresetManagerError.saveFailed
        }
        return preset
    }

    /// Copy a bundle directory tree in its entirety. Used by the
    /// right-click "Duplicate bundle" UI path and by `savePreset`'s
    /// `duplicateFrom` branch (Save As). Caller is responsible for
    /// ensuring `dest` doesn't already exist.
    private func copyBundleTree(from src: URL, to dest: URL) throws {
        try fileManager.copyItem(at: src, to: dest)
        AppGroupContainer.stripQuarantine(at: dest)
    }

    /// Drop a starter `ui/index.html` into an existing user bundle and return
    /// the URL of the newly-written file.
    ///
    /// This is the "+ Add Custom UI" action the main view exposes when a
    /// bundle doesn't yet ship a custom HTML/JS UI. It doesn't commit —
    /// callers route the new file through `PresetGitCoordinator.recordSave`
    /// so the commit appears alongside every other preset mutation in
    /// `git log`.
    ///
    /// Caller must ensure the bundle is writable (`!preset.isFactory`);
    /// factory bundles throw `PresetManagerError.saveFailed` because their
    /// Resources directory is read-only under the hardened runtime.
    @discardableResult
    func scaffoldCustomUI(for bundle: PresetBundle) throws -> URL {
        // Factory bundles live inside the extension's Resources, which is
        // read-only. The caller shouldn't reach here for a factory bundle,
        // but fail loudly just in case.
        if !fileManager.isWritableFile(atPath: bundle.rootURL.path) {
            throw PresetManagerError.saveFailed
        }

        let uiDir = bundle.rootURL.appendingPathComponent("ui", isDirectory: true)
        try fileManager.createDirectory(at: uiDir, withIntermediateDirectories: true)

        let indexURL = uiDir.appendingPathComponent("index.html")
        // Don't clobber — if the user already has a ui/index.html on disk but
        // the manifest doesn't reference it, preserve their work and just
        // rewrite the manifest.
        if !fileManager.fileExists(atPath: indexURL.path) {
            try PresetBundle.starterIndexHTML().write(
                to: indexURL, atomically: true, encoding: .utf8
            )
        }

        // Make sure the manifest advertises the UI. Without this, the
        // `PresetBundle.hasCustomUI` check stays false and the toggle never
        // flips to "available."
        let manifestURL = bundle.rootURL.appendingPathComponent(PresetManifest.filename)
        let updatedManifest: PresetManifest = {
            if bundle.manifest.ui != nil { return bundle.manifest }
            // IMPORTANT: pass `params` through. The memberwise init
            // defaults optional fields to nil when omitted, so forgetting
            // this here silently drops manifest-v2 param declarations
            // and the bundle reverts to the v1 DSP-extraction path on
            // the next load.
            return PresetManifest(
                schemaVersion: bundle.manifest.schemaVersion,
                entry: bundle.manifest.entry,
                language: bundle.manifest.language,
                ui: PresetManifest.UI(
                    entryHTML: "ui/index.html",
                    width: 520,
                    height: 260,
                    fps: 30,
                    audioFrames: false
                ),
                params: bundle.manifest.params,
                meta: bundle.manifest.meta
            )
        }()
        try updatedManifest.jsonData().write(to: manifestURL)

        refreshPresets()
        return indexURL
    }

    // MARK: - Bundle file helpers (used by BundleFileBrowser)

    /// Template for a newly-created bundle file. The browser's New File flow
    /// picks one based on the filename extension the user typed.
    enum NewFileTemplate {
        case blankHTML
        case blankCSS
        case blankJS
        case empty

        var initialContent: String {
            switch self {
            case .blankHTML:
                return "<!DOCTYPE html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n</head>\n<body>\n</body>\n</html>\n"
            case .blankCSS:
                return "/* styles */\n"
            case .blankJS:
                return "// script\n"
            case .empty:
                return ""
            }
        }

        /// Best-match template for a filename. Used by the New File popover so
        /// typing `styles.css` auto-selects the CSS template.
        static func match(forFilename name: String) -> NewFileTemplate {
            let ext = (name as NSString).pathExtension.lowercased()
            switch ext {
            case "html", "htm": return .blankHTML
            case "css":         return .blankCSS
            case "js", "mjs":   return .blankJS
            default:            return .empty
            }
        }
    }

    /// Errors raised by the file-browser helpers. Callers surface these via
    /// `errorMessage` in the main view; the strings are UI-ready.
    enum BundleFileError: LocalizedError {
        case notEditable
        case outsideBundle
        case alreadyExists
        case manifestProtected
        case entryScriptProtected
        case notFound

        var errorDescription: String? {
            switch self {
            case .notEditable: return "This preset bundle is read-only."
            case .outsideBundle: return "That path is outside the bundle."
            case .alreadyExists: return "A file or folder already exists at that path."
            case .manifestProtected: return "manifest.json can't be deleted — it would invalidate the bundle."
            case .entryScriptProtected: return "The entry script can't be deleted from the file browser — edit it or save-as instead."
            case .notFound: return "File not found."
            }
        }
    }

    /// Check that `relativePath` stays inside the bundle root. Prevents
    /// `..` path tricks from the file browser reaching out of the sandbox.
    ///
    /// Uses `resolvingSymlinksInPath()` on both sides so `/var/...` vs
    /// `/private/var/...` doesn't falsely report "outside bundle" on
    /// macOS tempdirs (where the URL `FileManager.default.temporaryDirectory`
    /// hands out and the one re-discovered via `contentsOfDirectory`
    /// disagree on symlink resolution).
    private func resolveBundlePath(in bundle: PresetBundle, relativePath: String) throws -> URL {
        let candidate = bundle.rootURL.appendingPathComponent(relativePath)
        // Reject explicit escape attempts (..) without relying on path
        // canonicalization, which can't resolve components that don't
        // exist on disk yet (e.g., a file we're about to create).
        let normalizedRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for component in normalizedRel.split(separator: "/") {
            if component == ".." {
                throw BundleFileError.outsideBundle
            }
        }
        let rootResolved = bundle.rootURL.resolvingSymlinksInPath().path
        let candidateResolved = candidate.resolvingSymlinksInPath().path
        // Also accept the unresolved form for paths that don't exist yet
        // (resolvingSymlinksInPath returns the same string if the path
        // isn't a symlink or doesn't exist, but belt-and-suspenders).
        guard candidateResolved.hasPrefix(rootResolved)
            || candidate.path.hasPrefix(bundle.rootURL.path) else {
            throw BundleFileError.outsideBundle
        }
        return candidate
    }

    /// Resolve `bundle.rootURL` to the preset it belongs to and confirm it's
    /// writable. Factory bundles always throw `notEditable`.
    private func ensureEditable(_ bundle: PresetBundle) throws {
        // Factory bundles live in the extension's Resources, which is
        // read-only under the hardened runtime. Caller shouldn't reach
        // here for a factory; guard anyway.
        if !fileManager.isWritableFile(atPath: bundle.rootURL.path) {
            throw BundleFileError.notEditable
        }
    }

    /// Create a new file inside an editable bundle. Intermediate directories
    /// are created as needed. Returns the resulting URL so the caller can
    /// open it in the editor and route it through `recordSave`.
    @discardableResult
    func createBundleFile(
        in bundle: PresetBundle,
        relativePath: String,
        template: NewFileTemplate = .empty
    ) throws -> URL {
        try ensureEditable(bundle)
        let url = try resolveBundlePath(in: bundle, relativePath: relativePath)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw BundleFileError.alreadyExists
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try template.initialContent.write(to: url, atomically: true, encoding: .utf8)
        AppGroupContainer.stripQuarantine(at: url)
        refreshPresets()
        return url
    }

    /// Create a new empty folder inside an editable bundle.
    @discardableResult
    func createBundleFolder(in bundle: PresetBundle, relativePath: String) throws -> URL {
        try ensureEditable(bundle)
        let url = try resolveBundlePath(in: bundle, relativePath: relativePath)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw BundleFileError.alreadyExists
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        AppGroupContainer.stripQuarantine(at: url)
        refreshPresets()
        return url
    }

    /// Result of `renameBundleFile`: the two endpoints of the move, plus any
    /// manifest URL that also had to be rewritten (e.g. when the entry script
    /// was renamed). Callers pass all three to `gc.recordRename` +
    /// `recordSave` so the commit captures the full diff.
    struct RenameResult {
        let oldURL: URL
        let newURL: URL
        /// Present when the rename forced a manifest rewrite. Nil otherwise.
        let manifestURL: URL?
    }

    /// Rename a file or directory inside an editable bundle. Keeps the
    /// manifest in sync: renaming `process.py` → `dsp.py` rewrites
    /// `manifest.entry`; renaming `ui/index.html` → `ui/main.html` rewrites
    /// `manifest.ui.entryHTML`. Those coordinated updates happen atomically
    /// so the bundle stays loadable through the operation.
    @discardableResult
    func renameBundleFile(
        in bundle: PresetBundle,
        from oldRelPath: String,
        to newRelPath: String
    ) throws -> RenameResult {
        try ensureEditable(bundle)
        let oldURL = try resolveBundlePath(in: bundle, relativePath: oldRelPath)
        let newURL = try resolveBundlePath(in: bundle, relativePath: newRelPath)

        guard fileManager.fileExists(atPath: oldURL.path) else {
            throw BundleFileError.notFound
        }
        if oldURL != newURL {
            guard !fileManager.fileExists(atPath: newURL.path) else {
                throw BundleFileError.alreadyExists
            }
        }

        try fileManager.createDirectory(
            at: newURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if oldURL != newURL {
            try fileManager.moveItem(at: oldURL, to: newURL)
        }

        // Keep the manifest consistent with the new layout.
        var manifestURL: URL? = nil
        let manifestPath = bundle.rootURL.appendingPathComponent(PresetManifest.filename)
        let trimmedOld = oldRelPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedNew = newRelPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var manifest = bundle.manifest
        var manifestChanged = false
        if manifest.entry == trimmedOld {
            manifest.entry = trimmedNew
            manifestChanged = true
        }
        if let ui = manifest.ui, ui.entryHTML == trimmedOld {
            manifest.ui = PresetManifest.UI(
                entryHTML: trimmedNew,
                width: ui.width,
                height: ui.height,
                fps: ui.fps,
                audioFrames: ui.audioFrames
            )
            manifestChanged = true
        }
        if manifestChanged {
            try manifest.jsonData().write(to: manifestPath)
            manifestURL = manifestPath
        }

        refreshPresets()
        return RenameResult(oldURL: oldURL, newURL: newURL, manifestURL: manifestURL)
    }

    /// Remove a file from an editable bundle. `manifest.json` and the entry
    /// script are protected — deleting them would brick the bundle.
    func deleteBundleFile(in bundle: PresetBundle, relativePath: String) throws {
        try ensureEditable(bundle)
        let url = try resolveBundlePath(in: bundle, relativePath: relativePath)
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed == PresetManifest.filename {
            throw BundleFileError.manifestProtected
        }
        if trimmed == bundle.manifest.entry {
            throw BundleFileError.entryScriptProtected
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw BundleFileError.notFound
        }
        try fileManager.removeItem(at: url)
        refreshPresets()
    }

    /// Duplicate a file inside an editable bundle. The copy's name is the
    /// source's stem + " 2" (" 3", etc.) to avoid clobbering.
    @discardableResult
    func duplicateBundleFile(in bundle: PresetBundle, relativePath: String) throws -> URL {
        try ensureEditable(bundle)
        let sourceURL = try resolveBundlePath(in: bundle, relativePath: relativePath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw BundleFileError.notFound
        }

        let parent = sourceURL.deletingLastPathComponent()
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var copyURL = parent.appendingPathComponent("\(stem) 2\(ext.isEmpty ? "" : ".")\(ext)")
        var suffix = 2
        while fileManager.fileExists(atPath: copyURL.path) {
            suffix += 1
            copyURL = parent.appendingPathComponent("\(stem) \(suffix)\(ext.isEmpty ? "" : ".")\(ext)")
        }
        try fileManager.copyItem(at: sourceURL, to: copyURL)
        refreshPresets()
        return copyURL
    }

    /// Fork a factory bundle into a writable user bundle under `presetsURL`.
    /// The new name defaults to `"Copy of <factory name>"`, deduped against
    /// existing user presets. Returns the loaded bundle view so callers can
    /// set it as the current preset and open the equivalent file in the
    /// editor.
    @discardableResult
    func duplicateFactoryBundle(source: PresetBundle) throws -> PresetBundle {
        let baseName = uniqueName(baseName: "Copy of \(source.name)")
        let sanitized = sanitizeFilename(baseName)
        let destURL = presetsURL.appendingPathComponent(
            "\(sanitized).\(PresetBundle.bundleExtension)",
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destURL.path) else {
            throw BundleFileError.alreadyExists
        }
        try copyBundleTree(from: source.rootURL, to: destURL)
        refreshPresets()
        guard let forked = PresetBundle.load(from: destURL) else {
            throw PresetManagerError.saveFailed
        }
        return forked
    }

    /// Duplicate a source bundle (factory OR user) into a new user bundle
    /// with an explicit destination name. Mirrors the right-click
    /// "Duplicate bundle" UI path but exposes an explicit `destName`
    /// instead of auto-generating "Copy of …".
    ///
    /// Used by the MCP `duplicate_bundle` tool so an agent can fork a
    /// preset (typically a factory it wants to extend) and end up with a
    /// FULL copy of the bundle — manifest, ui/, ui/assets/, entry script
    /// — in one tool call. Without this, agents have only `save_preset`,
    /// which produces a stripped-down clone (just the entry script with
    /// a default manifest), silently losing the source bundle's UI.
    ///
    /// Optionally replaces the entry script after copying — useful when
    /// the agent's intent is "fork this and run my modified DSP." The
    /// caller is still responsible for any subsequent manifest edits
    /// (e.g. updating the params block to match new metadata).
    @discardableResult
    func duplicateBundle(
        source: PresetBundle,
        destName: String,
        replacingEntryWith newSource: String? = nil
    ) throws -> Preset {
        let sanitized = sanitizeFilename(destName)
        guard !sanitized.isEmpty else {
            throw PresetManagerError.invalidName
        }
        let destURL = presetsURL.appendingPathComponent(
            "\(sanitized).\(PresetBundle.bundleExtension)",
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: destURL.path) else {
            throw BundleFileError.alreadyExists
        }
        try copyBundleTree(from: source.rootURL, to: destURL)

        // Optional entry replacement. The destination's entry path is
        // taken from the COPIED manifest (not the source's in-memory
        // bundle, which could be stale if loaded from a cache). Using
        // the on-disk manifest also respects any intentional drift
        // between the source's manifest and entry filename.
        if let newSource {
            let manifestURL = destURL.appendingPathComponent(PresetManifest.filename)
            let manifest: PresetManifest = {
                if let data = try? Data(contentsOf: manifestURL),
                   let parsed = try? JSONDecoder().decode(PresetManifest.self, from: data) {
                    return parsed
                }
                return source.manifest
            }()
            let entryURL = destURL.appendingPathComponent(manifest.entry)
            try newSource.write(to: entryURL, atomically: true, encoding: .utf8)
            AppGroupContainer.stripQuarantine(at: entryURL)
        }

        refreshPresets()
        guard let preset = presets.first(where: { $0.id == "user:\(sanitized)" }) else {
            throw PresetManagerError.saveFailed
        }
        log.info("Duplicated bundle \(source.name, privacy: .public) -> \(sanitized, privacy: .public)")
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
            startBundleWatcher(for: nil)
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
            // Re-key the watcher onto the new bundle root — the old path
            // no longer exists post-move.
            startBundleWatcher(for: renamedPreset)
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
