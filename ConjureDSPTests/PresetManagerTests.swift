import Testing
import Foundation

struct PresetManagerTests {

    // MARK: - Helpers

    /// Extension bundle containing factory preset .py resources.
    private static var extensionBundle: Bundle {
        get throws {
            guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
                throw TestError("Bundle.main.builtInPlugInsURL is nil")
            }
            let appexURL = plugInsURL.appendingPathComponent("ConjureDSPExtension.appex")
            guard let bundle = Bundle(url: appexURL) else {
                throw TestError("Could not load extension bundle at \(appexURL.path)")
            }
            return bundle
        }
    }

    private struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Creates a PresetManager with a temp directory for user presets.
    @MainActor
    private static func makeManager() throws -> (PresetManager, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetManagerTests_\(UUID().uuidString)", isDirectory: true)
        let manager = PresetManager(
            extensionBundle: try extensionBundle,
            userPresetsURL: tempDir
        )
        return (manager, tempDir)
    }

    /// Cleans up a temp directory.
    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Factory Preset Discovery

    @Test @MainActor func discoversFactoryPresets() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let factory = manager.presets.filter(\.isFactory)
        let expectedCount = FactoryPresetRegistry.entries.count
        #expect(factory.count == expectedCount, "Should have \(expectedCount) factory presets")
        let names = factory.map(\.name)
        #expect(names.contains("Passthrough (Python)"))
        #expect(names.contains("Tremolo (Python)"))
        #expect(names.contains("Bitcrush (Python)"))
        #expect(names.contains("Passthrough (Rust)"))
        #expect(names.contains("Tremolo (Rust)"))
        #expect(names.contains("Bitcrush (Rust)"))
        #expect(names.contains("Compressor (Python)"))
        #expect(names.contains("Compressor (Rust)"))
        #expect(names.contains("Soft Clip (Python)"))
        #expect(names.contains("Chorus (Rust)"))
        #expect(names.contains("Delay (Python)"))
    }

    @Test @MainActor func factoryPresetsHavePresetNumbers() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let factory = manager.presets.filter(\.isFactory)
        for preset in factory {
            #expect(preset.factoryPresetNumber != nil, "\(preset.name) should have a factory preset number")
        }
    }

    @Test @MainActor func factoryPresetsAreLoadable() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let factory = manager.presets.filter(\.isFactory)
        for preset in factory {
            guard let source = manager.loadSource(for: preset) else {
                Issue.record("Should load source for factory preset \(preset.name)")
                continue
            }
            if preset.language == .rust {
                #expect(source.contains("fn process"), "Rust factory preset \(preset.name) should contain fn process")
            } else {
                #expect(source.contains("def process"), "Python factory preset \(preset.name) should contain def process")
            }
        }
    }

    @Test @MainActor func factoryPresetsHaveCorrectLanguage() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let factory = manager.presets.filter(\.isFactory)
        let rustPresets = factory.filter { $0.language == .rust }
        let pythonPresets = factory.filter { $0.language == .python }
        let expectedRust = FactoryPresetRegistry.entries.filter { $0.language == .rust }.count
        let expectedPython = FactoryPresetRegistry.entries.filter { $0.language == .python }.count
        #expect(rustPresets.count == expectedRust, "Should have exactly \(expectedRust) Rust factory presets")
        #expect(pythonPresets.count == expectedPython, "Should have exactly \(expectedPython) Python factory presets")
    }

    // MARK: - User Preset CRUD

    @Test @MainActor func saveAndLoadUserPreset() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "def process(inputs, outputs, frame_count, sample_rate):\n    pass\n"
        let preset = try manager.saveUserBundle(name: "My Effect", source: script)

        #expect(preset.name == "My Effect")
        #expect(!preset.isFactory)
        #expect(preset.factoryPresetNumber == nil)

        let loaded = manager.loadSource(for: preset)
        #expect(loaded == script)
    }

    @Test @MainActor func saveAndLoadRustUserPreset() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "fn process() {}\n"
        let preset = try manager.saveUserBundle(name: "My Rust Effect", source: script, language: .rust)

        #expect(preset.name == "My Rust Effect")
        #expect(preset.language == .rust)
        #expect(!preset.isFactory)

        let loaded = manager.loadSource(for: preset)
        #expect(loaded == script)
    }

    @Test @MainActor func savedPresetAppearsInList() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "def process(inputs, outputs, frame_count, sample_rate):\n    pass\n"
        try manager.saveUserBundle(name: "Test Preset", source: script)

        let userPresets = manager.presets.filter { !$0.isFactory }
        #expect(userPresets.count == 1)
        #expect(userPresets[0].name == "Test Preset")
    }

    @Test @MainActor func deleteUserPreset() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "pass\n"
        let preset = try manager.saveUserBundle(name: "To Delete", source: script)
        #expect(manager.presets.contains(where: { $0.id == preset.id }))

        try manager.deleteUserPreset(preset)
        #expect(!manager.presets.contains(where: { $0.id == preset.id }))
    }

    @Test @MainActor func deleteCurrentPresetClearsCurrent() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.saveUserBundle(name: "Active", source: "pass\n")
        manager.setCurrentPreset(preset, source: "pass\n")
        #expect(manager.currentPreset?.id == preset.id)

        try manager.deleteUserPreset(preset)
        #expect(manager.currentPreset == nil)
        #expect(manager.isModified == false)
    }

    @Test @MainActor func overwriteExistingUserPreset() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.saveUserBundle(name: "Evolving", source: "# version 1\n")
        try manager.saveUserBundle(name: "Evolving", source: "# version 2\n")

        let userPresets = manager.presets.filter { !$0.isFactory && $0.name == "Evolving" }
        #expect(userPresets.count == 1, "Should have exactly one preset named 'Evolving'")

        let loaded = manager.loadSource(for: userPresets[0])
        #expect(loaded == "# version 2\n")
    }

    // MARK: - Modification Tracking

    @Test @MainActor func isModifiedTracking() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let source = "# original\n"
        let preset = try manager.saveUserBundle(name: "Track Me", source: source)
        manager.setCurrentPreset(preset, source: source)

        #expect(manager.isModified == false)

        manager.scriptDidChange(to: "# edited\n")
        #expect(manager.isModified == true)

        manager.scriptDidChange(to: source)
        #expect(manager.isModified == false, "Reverting to original should clear isModified")
    }

    @Test @MainActor func isModifiedWhenNoPresetLoaded() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        manager.setCurrentPreset(nil, source: nil)
        manager.scriptDidChange(to: "some text")
        #expect(manager.isModified == true)
    }

    // MARK: - Name Helpers

    @Test @MainActor func uniqueNameNoConflict() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let name = manager.uniqueName(baseName: "Fresh Name")
        #expect(name == "Fresh Name")
    }

    @Test @MainActor func uniqueNameWithConflict() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.saveUserBundle(name: "Conflict", source: "pass\n")
        let name = manager.uniqueName(baseName: "Conflict")
        #expect(name == "Conflict 2")
    }

    @Test @MainActor func uniqueNameMultipleConflicts() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.saveUserBundle(name: "Effect", source: "pass\n")
        try manager.saveUserBundle(name: "Effect 2", source: "pass\n")
        let name = manager.uniqueName(baseName: "Effect")
        #expect(name == "Effect 3")
    }

    @Test @MainActor func sanitizeFilenameRemovesUnsafeChars() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        #expect(manager.sanitizeFilename("my/preset") == "my_preset")
        #expect(manager.sanitizeFilename("test:file") == "test_file")
        #expect(manager.sanitizeFilename("  trimmed  ") == "trimmed")
        #expect(manager.sanitizeFilename("normal") == "normal")
    }

    @Test @MainActor func invalidNameThrows() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        #expect(throws: PresetManagerError.self) {
            try manager.saveUserBundle(name: "   ", source: "pass\n")
        }
    }

    @Test @MainActor func userPresetExistsCheck() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        #expect(!manager.userPresetExists(name: "Nope"))
        try manager.saveUserBundle(name: "Exists", source: "pass\n")
        #expect(manager.userPresetExists(name: "Exists"))
    }

    // MARK: - External Changes

    @Test @MainActor func refreshPicksUpExternalFile() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Write a file directly (simulating user copying a .py file)
        let url = tempDir.appendingPathComponent("External.py")
        try "# external\n".write(to: url, atomically: true, encoding: .utf8)

        manager.refreshPresets()

        let userPresets = manager.presets.filter { !$0.isFactory }
        #expect(userPresets.contains(where: { $0.name == "External" }))
    }

    @Test @MainActor func nonScriptFilesAreIgnored() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try "not a preset".write(
            to: tempDir.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8
        )
        try "also not".write(
            to: tempDir.appendingPathComponent("script.js"),
            atomically: true, encoding: .utf8
        )

        manager.refreshPresets()

        let userPresets = manager.presets.filter { !$0.isFactory }
        #expect(userPresets.isEmpty, "Non-.py/.rs files should be ignored")
    }

    @Test @MainActor func rsFilesAreDiscovered() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try "fn process() {}".write(
            to: tempDir.appendingPathComponent("MyEffect.rs"),
            atomically: true, encoding: .utf8
        )

        manager.refreshPresets()

        let userPresets = manager.presets.filter { !$0.isFactory }
        #expect(userPresets.count == 1)
        #expect(userPresets[0].name == "MyEffect")
        #expect(userPresets[0].language == .rust)
    }

    // MARK: - Empty State

    @Test @MainActor func emptyUserDirectoryShowsOnlyFactory() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let expectedCount = FactoryPresetRegistry.entries.count
        #expect(manager.presets.count == expectedCount, "Should only have factory presets")
        let allFactory = manager.presets.allSatisfy(\.isFactory)
        #expect(allFactory)
    }

    @Test @MainActor func userPresetsDirectoryIsCreated() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetManagerTests_\(UUID().uuidString)", isDirectory: true)
        defer { Self.cleanup(tempDir) }

        #expect(!FileManager.default.fileExists(atPath: tempDir.path))

        let _ = PresetManager(
            extensionBundle: try Self.extensionBundle,
            userPresetsURL: tempDir
        )

        #expect(FileManager.default.fileExists(atPath: tempDir.path),
               "PresetManager should create user presets directory")
    }

    // MARK: - Factory vs User Separation

    @Test @MainActor func factoryAndUserPresetsCanShareNames() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Save a user preset with the same name as a factory preset
        try manager.saveUserBundle(name: "Tremolo (Python)", source: "# user tremolo\n")

        let tremolos = manager.presets.filter { $0.name == "Tremolo (Python)" }
        #expect(tremolos.count == 2, "Should have both factory and user 'Tremolo (Python)'")

        let factory = tremolos.first(where: \.isFactory)
        let user = tremolos.first(where: { !$0.isFactory })
        #expect(factory != nil)
        #expect(user != nil)
        #expect(factory!.id != user!.id, "Factory and user presets should have different IDs")
    }

    @Test @MainActor func cannotDeleteFactoryPreset() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let factory = manager.presets.first(where: \.isFactory)!
        // deleteUserPreset should be a no-op for factory presets (guard returns early)
        try manager.deleteUserPreset(factory)
        #expect(manager.presets.contains(where: { $0.id == factory.id }),
               "Factory preset should not be deleted")
    }

    // MARK: - Rename

    @Test @MainActor func renameUserPreset() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "def process(inputs, outputs, frame_count, sample_rate):\n    pass\n"
        try manager.saveUserBundle(name: "Alpha", source: script)

        let renamed = try manager.renamePreset(
            manager.presets.first(where: { $0.name == "Alpha" && !$0.isFactory })!,
            to: "Beta"
        )

        #expect(renamed.name == "Beta")
        #expect(renamed.id == "user:bundle:Beta")
        #expect(!manager.presets.contains(where: { $0.name == "Alpha" && !$0.isFactory }))
        #expect(manager.presets.contains(where: { $0.name == "Beta" && !$0.isFactory }))
        #expect(manager.loadSource(for: renamed) == script)
    }

    /// Renaming a legacy single-file repo preset still fires
    /// `onRepoPresetRenamed`, preserving backward compat for users with
    /// pre-bundle repo caches. Bundle repo sync is a separate Phase A'.
    @Test @MainActor func renameLegacyRepoPresetFiresCallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetManagerTests_\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempDir.appendingPathComponent("RepoPresets", isDirectory: true)
        let manager = PresetManager(
            extensionBundle: try Self.extensionBundle,
            userPresetsURL: tempDir,
            repoPresetsURL: repoDir
        )
        defer { Self.cleanup(tempDir) }

        // Write a legacy single-file repo preset directly to disk.
        let script = "# repo script\n"
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try script.write(to: repoDir.appendingPathComponent("RepoAlpha.py"), atomically: true, encoding: .utf8)
        manager.refreshPresets()

        var callbackArgs: (oldName: String, newName: String, source: String, language: ScriptLanguage)?
        manager.onRepoPresetRenamed = { oldName, newName, source, language in
            callbackArgs = (oldName, newName, source, language)
        }

        let preset = manager.presets.first(where: { $0.name == "RepoAlpha" && $0.isRepo })!
        let renamed = try manager.renamePreset(preset, to: "RepoBeta")

        #expect(renamed.name == "RepoBeta")
        #expect(renamed.id == "repo:RepoBeta.py")
        #expect(callbackArgs?.oldName == "RepoAlpha")
        #expect(callbackArgs?.newName == "RepoBeta")
        #expect(callbackArgs?.source == script)
        #expect(callbackArgs?.language == .python)
    }

    /// Renaming a repo *bundle* does NOT fire the legacy callback — bundle
    /// GitHub sync is handled separately.
    @Test @MainActor func saveRepoBundleFiresBundleSavedCallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetManagerTests_\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempDir.appendingPathComponent("RepoPresets", isDirectory: true)
        let manager = PresetManager(
            extensionBundle: try Self.extensionBundle,
            userPresetsURL: tempDir,
            repoPresetsURL: repoDir
        )
        defer { Self.cleanup(tempDir) }

        var firedName: String?
        var firedURL: URL?
        manager.onRepoBundleSaved = { name, url in
            firedName = name
            firedURL = url
        }

        try manager.saveRepoBundle(name: "BundleA", source: "# x\n")

        #expect(firedName == "BundleA")
        #expect(firedURL?.lastPathComponent == "BundleA.cdp")
        // URL points at a real bundle directory on disk.
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: firedURL?.path ?? "", isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test @MainActor func deleteRepoBundleFiresBundleDeletedCallbackNotLegacy() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetManagerTests_\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempDir.appendingPathComponent("RepoPresets", isDirectory: true)
        let manager = PresetManager(
            extensionBundle: try Self.extensionBundle,
            userPresetsURL: tempDir,
            repoPresetsURL: repoDir
        )
        defer { Self.cleanup(tempDir) }

        try manager.saveRepoBundle(name: "ToDelete", source: "# x\n")

        var bundleDeletedName: String?
        var legacyFired = false
        manager.onRepoBundleDeleted = { bundleDeletedName = $0 }
        manager.onRepoPresetDeleted = { _, _ in legacyFired = true }

        let preset = manager.presets.first { $0.name == "ToDelete" && $0.isRepo }!
        try manager.deletePreset(preset)

        #expect(bundleDeletedName == "ToDelete")
        #expect(legacyFired == false)
    }

    @Test @MainActor func renameRepoBundleFiresBundleRenamedCallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetManagerTests_\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempDir.appendingPathComponent("RepoPresets", isDirectory: true)
        let manager = PresetManager(
            extensionBundle: try Self.extensionBundle,
            userPresetsURL: tempDir,
            repoPresetsURL: repoDir
        )
        defer { Self.cleanup(tempDir) }

        try manager.saveRepoBundle(name: "OldName", source: "# x\n")

        var firedOld: String?
        var firedNew: String?
        var firedURL: URL?
        manager.onRepoBundleRenamed = { old, new, url in
            firedOld = old
            firedNew = new
            firedURL = url
        }

        let preset = manager.presets.first { $0.name == "OldName" && $0.isRepo }!
        _ = try manager.renamePreset(preset, to: "NewName")

        #expect(firedOld == "OldName")
        #expect(firedNew == "NewName")
        #expect(firedURL?.lastPathComponent == "NewName.cdp")
    }

    @Test @MainActor func renameRepoBundleDoesNotFireLegacyCallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetManagerTests_\(UUID().uuidString)", isDirectory: true)
        let repoDir = tempDir.appendingPathComponent("RepoPresets", isDirectory: true)
        let manager = PresetManager(
            extensionBundle: try Self.extensionBundle,
            userPresetsURL: tempDir,
            repoPresetsURL: repoDir
        )
        defer { Self.cleanup(tempDir) }

        try manager.saveRepoBundle(name: "RepoAlpha", source: "# s\n")

        var callbackFired = false
        manager.onRepoPresetRenamed = { _, _, _, _ in callbackFired = true }

        let preset = manager.presets.first(where: { $0.name == "RepoAlpha" && $0.isRepo })!
        let renamed = try manager.renamePreset(preset, to: "RepoBeta")

        #expect(renamed.id == "repo:bundle:RepoBeta")
        #expect(callbackFired == false)
    }

    @Test @MainActor func renameCurrentPresetUpdatesCurrent() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "# active preset\n"
        let preset = try manager.saveUserBundle(name: "Current", source: script)
        manager.setCurrentPreset(preset, source: script)
        manager.scriptDidChange(to: "# edited\n")
        #expect(manager.isModified == true)

        let renamed = try manager.renamePreset(preset, to: "Renamed")

        #expect(manager.currentPreset?.id == renamed.id)
        #expect(manager.currentPreset?.name == "Renamed")
        #expect(manager.loadedSource == script)
        #expect(manager.isModified == true)
    }

    @Test @MainActor func renameSameNameIsNoOp() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.saveUserBundle(name: "Same", source: "pass\n")
        let result = try manager.renamePreset(preset, to: "Same")

        #expect(result.id == preset.id)
        #expect(result.name == "Same")
    }

    @Test @MainActor func renameFactoryPresetThrows() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let factory = manager.presets.first(where: \.isFactory)!
        #expect(throws: PresetManagerError.self) {
            try manager.renamePreset(factory, to: "New Name")
        }
    }

    @Test @MainActor func renameToEmptyNameThrows() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.saveUserBundle(name: "Valid", source: "pass\n")
        #expect(throws: PresetManagerError.self) {
            try manager.renamePreset(preset, to: "   ")
        }
    }

    @Test @MainActor func renameToConflictingNameThrows() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.saveUserBundle(name: "Existing", source: "pass\n")
        let preset = try manager.saveUserBundle(name: "ToRename", source: "pass\n")

        #expect(throws: PresetManagerError.self) {
            try manager.renamePreset(preset, to: "Existing")
        }
    }

    @Test @MainActor func renamePreservesLanguage() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.saveUserBundle(name: "RustEffect", source: "fn process() {}\n", language: .rust)
        let renamed = try manager.renamePreset(preset, to: "RenamedRust")

        #expect(renamed.language == .rust)
        #expect(renamed.id == "user:bundle:RenamedRust")
        #expect(manager.loadSource(for: renamed) == "fn process() {}\n")
    }

    @Test @MainActor func renameNonCurrentDoesNotAffectCurrent() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let presetA = try manager.saveUserBundle(name: "A", source: "# a\n")
        let presetB = try manager.saveUserBundle(name: "B", source: "# b\n")
        manager.setCurrentPreset(presetA, source: "# a\n")

        try manager.renamePreset(presetB, to: "C")

        #expect(manager.currentPreset?.id == presetA.id)
        #expect(manager.currentPreset?.name == "A")
    }

    // MARK: - Bundle Presets

    @Test @MainActor func saveUserBundleCreatesDirectoryWithManifest() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "# bundle preset\n"
        let preset = try manager.saveUserBundle(name: "My Bundle", source: script, language: .python)

        #expect(preset.isBundle)
        #expect(preset.isUser)
        #expect(preset.id == "user:bundle:My Bundle")
        #expect(preset.language == .python)

        let bundleURL = tempDir.appendingPathComponent("My Bundle.cdp", isDirectory: true)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: bundleURL.path))
        #expect(fm.fileExists(atPath: bundleURL.appendingPathComponent("manifest.json").path))
        #expect(fm.fileExists(atPath: bundleURL.appendingPathComponent("process.py").path))
        // Default save does NOT scaffold ui/index.html.
        #expect(!fm.fileExists(atPath: bundleURL.appendingPathComponent("ui/index.html").path))
    }

    @Test @MainActor func saveUserBundleScaffoldsUIWhenRequested() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.saveUserBundle(name: "WithUI", source: "# x\n", scaffoldUI: true)

        let bundleURL = tempDir.appendingPathComponent("WithUI.cdp", isDirectory: true)
        let htmlURL = bundleURL.appendingPathComponent("ui/index.html")
        #expect(FileManager.default.fileExists(atPath: htmlURL.path))
        // Scaffolded HTML contains the bridge API the starter template uses.
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        #expect(html.contains("window.ConjureDSP"))
    }

    @Test @MainActor func bundleWithManifestUIBlockButNoHTMLIsNotCustomUI() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Default save: manifest has `ui` block, but no ui/index.html written.
        let preset = try manager.saveUserBundle(name: "Pending", source: "# x\n")
        let bundle = manager.loadBundle(for: preset)
        #expect(bundle != nil)
        #expect(bundle?.manifest.ui != nil) // block present
        #expect(bundle?.hasCustomUI == false) // but no HTML exists yet
    }

    @Test @MainActor func discoverPresetsIncludesBundles() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.saveUserBundle(name: "First", source: "# 1\n")
        try manager.saveUserBundle(name: "Second", source: "# 2\n", language: .rust)

        let userBundles = manager.presets.filter { $0.isUser && $0.isBundle }
        #expect(userBundles.count == 2)
        #expect(userBundles.contains { $0.name == "First" && $0.language == .python })
        #expect(userBundles.contains { $0.name == "Second" && $0.language == .rust })
    }

    @Test @MainActor func loadSourceReadsBundleEntryScript() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "# the real source\n"
        let preset = try manager.saveUserBundle(name: "HasSource", source: script)
        let read = manager.loadSource(for: preset)

        #expect(read == script)
    }

    @Test @MainActor func setCurrentBundlePopulatesCurrentBundle() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "# cur\n"
        let preset = try manager.saveUserBundle(name: "Current", source: script, scaffoldUI: true)
        manager.setCurrentPreset(preset, source: script)

        let bundle = manager.currentBundle
        #expect(bundle != nil)
        #expect(bundle?.hasCustomUI == true)
        #expect(bundle?.uiIndexURL?.lastPathComponent == "index.html")
    }

    @Test @MainActor func setCurrentLegacyPresetClearsCurrentBundle() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let bundle = try manager.saveUserBundle(name: "B", source: "# b\n")
        manager.setCurrentPreset(bundle, source: "# b\n")
        #expect(manager.currentBundle != nil)

        // Switch to a legacy single-file preset written directly to disk.
        try "# l\n".write(to: tempDir.appendingPathComponent("L.py"), atomically: true, encoding: .utf8)
        manager.refreshPresets()
        let legacy = manager.presets.first { $0.name == "L" && !$0.isBundle }!
        manager.setCurrentPreset(legacy, source: "# l\n")
        #expect(manager.currentBundle == nil)
    }

    @Test @MainActor func deleteBundleRemovesDirectoryAndEntry() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.saveUserBundle(name: "Doomed", source: "# x\n")
        let bundleURL = tempDir.appendingPathComponent("Doomed.cdp", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: bundleURL.path))

        try manager.deletePreset(preset)

        #expect(!FileManager.default.fileExists(atPath: bundleURL.path))
        #expect(!manager.presets.contains { $0.id == preset.id })
    }

    @Test @MainActor func renameBundlePreservesCdpSuffix() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.saveUserBundle(name: "Before", source: "# s\n")
        let renamed = try manager.renamePreset(preset, to: "After")

        #expect(renamed.name == "After")
        #expect(renamed.id == "user:bundle:After")
        let newURL = tempDir.appendingPathComponent("After.cdp", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Before.cdp").path))
    }

    @Test @MainActor func malformedBundleIsSkippedDuringDiscovery() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Create a directory with a manifest pointing to a missing entry script
        let badBundle = tempDir.appendingPathComponent("Broken.cdp", isDirectory: true)
        try FileManager.default.createDirectory(at: badBundle, withIntermediateDirectories: true)
        let badManifest = #"{"schemaVersion":1,"entry":"missing.py"}"#
        try badManifest.write(to: badBundle.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        manager.refreshPresets()

        #expect(!manager.presets.contains { $0.name == "Broken" })
    }

    @Test @MainActor func legacyAndBundlePresetsCoexist() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Legacy single-file preset written directly to disk (simulates a
        // user upgrading from a pre-bundle install).
        try "# l\n".write(to: tempDir.appendingPathComponent("Legacy.py"), atomically: true, encoding: .utf8)
        // New-style bundle saved via the API.
        try manager.saveUserBundle(name: "Bundled", source: "# b\n")
        manager.refreshPresets()

        let users = manager.presets.filter(\.isUser)
        #expect(users.count == 2)
        #expect(users.contains { $0.name == "Legacy" && !$0.isBundle })
        #expect(users.contains { $0.name == "Bundled" && $0.isBundle })
    }

    @Test @MainActor func bundleWithoutUIBlockHasNoCustomUI() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Build a bundle manually with UI disabled
        let bundleURL = tempDir.appendingPathComponent("NoUI.cdp", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifest = PresetBundle.defaultManifest(language: .python, includeUI: false)
        try manifest.jsonData().write(to: bundleURL.appendingPathComponent("manifest.json"))
        try "# x\n".write(to: bundleURL.appendingPathComponent("process.py"), atomically: true, encoding: .utf8)

        manager.refreshPresets()
        let preset = manager.presets.first { $0.name == "NoUI" }
        #expect(preset != nil)

        let bundle = manager.loadBundle(for: preset!)
        #expect(bundle != nil)
        #expect(bundle?.hasCustomUI == false)
    }
}
