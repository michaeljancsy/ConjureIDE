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
            presetsURL: tempDir
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
        let preset = try manager.savePreset(name: "My Effect", source: script)

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
        let preset = try manager.savePreset(name: "My Rust Effect", source: script, language: .rust)

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
        try manager.savePreset(name: "Test Preset", source: script)

        let userPresets = manager.presets.filter { !$0.isFactory }
        #expect(userPresets.count == 1)
        #expect(userPresets[0].name == "Test Preset")
    }

    @Test @MainActor func deleteUserPreset() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "pass\n"
        let preset = try manager.savePreset(name: "To Delete", source: script)
        #expect(manager.presets.contains(where: { $0.id == preset.id }))

        try manager.deleteUserPreset(preset)
        #expect(!manager.presets.contains(where: { $0.id == preset.id }))
    }

    @Test @MainActor func deleteCurrentPresetClearsCurrent() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "Active", source: "pass\n")
        manager.setCurrentPreset(preset, source: "pass\n")
        #expect(manager.currentPreset?.id == preset.id)

        try manager.deleteUserPreset(preset)
        #expect(manager.currentPreset == nil)
        #expect(manager.isModified == false)
    }

    @Test @MainActor func overwriteExistingUserPreset() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.savePreset(name: "Evolving", source: "# version 1\n")
        try manager.savePreset(name: "Evolving", source: "# version 2\n")

        let userPresets = manager.presets.filter { !$0.isFactory && $0.name == "Evolving" }
        #expect(userPresets.count == 1, "Should have exactly one preset named 'Evolving'")

        let loaded = manager.loadSource(for: userPresets[0])
        #expect(loaded == "# version 2\n")
    }

    // MARK: - Manifest Persistence on Cmd+S
    //
    // The bug has two halves and the tests here cover both:
    //
    //   1. **Disk persistence.** User edits manifest.json via the file
    //      browser, hits Cmd+S → PresetManager.savePreset was deleting the
    //      bundle and regenerating manifest.json from defaults. Only `ui/`
    //      survived, so every width/height/fps edit silently vanished.
    //      `manifestUserEditsSurviveResave` locks this in.
    //
    //   2. **Model reactivity.** Even if the edit lives on disk, the
    //      SwiftUI view must see the new values. The view reads
    //      `presetManager.currentBundle.manifest.ui.height` for its
    //      `.frame(height:)` — that only re-renders when `currentBundle`
    //      republishes after `refreshPresets()`. `currentBundleReflects
    //      ManifestChangesAfterRefresh` covers that plumbing: manifest
    //      value on disk → PresetBundle re-parse → currentBundle property
    //      updated → view would pick up the new height on next body eval.
    //
    // We don't exercise the actual SwiftUI re-render in these tests —
    // that would require an XCUITest against the AU ViewBridge, which is
    // brittle. Instead we pin both observable halves and rely on SwiftUI's
    // normal "read property in body → re-render on change" contract for
    // the glue.

    @Test @MainActor func manifestUserEditsSurviveResave() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Create the bundle via the New Preset / Save As code path.
        let preset = try manager.savePreset(
            name: "ManifestEdits",
            source: "# v1\n",
            language: .python,
            scaffoldUI: true
        )
        guard let bundleURL = preset.fileURL else {
            Issue.record("Saved preset missing fileURL")
            return
        }
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")

        // Simulate a user editing manifest.json via the file browser —
        // change height, fps, add a meta block. All things the default
        // manifest doesn't match.
        var manifestDict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)
        ) as! [String: Any]
        var uiDict = manifestDict["ui"] as! [String: Any]
        uiDict["height"] = 100
        uiDict["fps"] = 60
        manifestDict["ui"] = uiDict
        manifestDict["meta"] = ["author": "test", "version": "1.2.3"]
        let editedData = try JSONSerialization.data(
            withJSONObject: manifestDict,
            options: [.prettyPrinted]
        )
        try editedData.write(to: manifestURL)

        // Simulate Cmd+S on the entry script — same name, new source.
        // Pre-fix, this would delete the bundle and regenerate the manifest
        // from defaults, wiping every edit above.
        try manager.savePreset(
            name: "ManifestEdits",
            source: "# v2\n",
            language: .python
        )

        // Re-read the manifest and verify every user edit survived.
        let reloadedData = try Data(contentsOf: manifestURL)
        let reloaded = try JSONSerialization.jsonObject(with: reloadedData) as! [String: Any]
        let reloadedUI = reloaded["ui"] as! [String: Any]
        #expect(reloadedUI["height"] as? Int == 100,
               "User's ui.height edit must survive Cmd+S")
        #expect(reloadedUI["fps"] as? Int == 60,
               "User's ui.fps edit must survive Cmd+S")
        let reloadedMeta = reloaded["meta"] as? [String: Any]
        #expect(reloadedMeta?["author"] as? String == "test",
               "User's meta block must survive Cmd+S")

        // Sanity: the entry script DID update — we're not testing a total
        // no-op, just that manifest.json wasn't clobbered.
        let scriptURL = bundleURL.appendingPathComponent("process.py")
        let scriptContent = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(scriptContent == "# v2\n",
               "Entry script should be updated on save")
    }

    @Test @MainActor func currentBundleReflectsManifestChangesAfterRefresh() throws {
        // Half two of the bug: even if manifest.json survives on disk,
        // the SwiftUI view has to actually observe the new value. This
        // test confirms `presetManager.currentBundle` republishes with
        // the updated manifest after a save + refreshPresets cycle —
        // which is what the view binds its .frame(height:) to.
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(
            name: "Reactive",
            source: "# v1\n",
            language: .python,
            scaffoldUI: true
        )
        manager.setCurrentPreset(preset, source: "# v1\n")

        // Sanity: currentBundle reflects the fresh manifest's default height.
        let initialHeight = manager.currentBundle?.manifest.ui?.height
        #expect(initialHeight != nil,
               "Fresh bundle with scaffoldUI must expose a ui block")

        // Simulate the file-browser write path: edit manifest.json on disk,
        // then call the same refresh hook `scheduleAltFileSave` uses.
        guard let bundleURL = preset.fileURL else {
            Issue.record("Saved preset missing fileURL")
            return
        }
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        var manifestDict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)
        ) as! [String: Any]
        var uiDict = manifestDict["ui"] as! [String: Any]
        uiDict["height"] = 77
        manifestDict["ui"] = uiDict
        try JSONSerialization.data(
            withJSONObject: manifestDict,
            options: [.prettyPrinted]
        ).write(to: manifestURL)

        manager.refreshPresets()

        // currentBundle should now expose the new height — this is what
        // the view reads for its frame. If this assertion ever fails, the
        // view will keep rendering the old height until the user switches
        // presets and back, which is exactly the "changing manifest
        // doesn't trigger any changes" bug the user hit.
        let refreshedHeight = manager.currentBundle?.manifest.ui?.height
        #expect(refreshedHeight == 77,
               "currentBundle must republish with the on-disk manifest height, got \(refreshedHeight ?? -1)")
    }

    @Test @MainActor func resaveRespectsManifestCustomEntryPath() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(
            name: "CustomEntry",
            source: "# v1\n",
            language: .python
        )
        guard let bundleURL = preset.fileURL else {
            Issue.record("Saved preset missing fileURL")
            return
        }
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")

        // User renames entry from "process.py" → "dsp.py" via a manifest edit
        // plus a file-browser rename (the rename itself is out of scope; we
        // just simulate the end state).
        var manifestDict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)
        ) as! [String: Any]
        manifestDict["entry"] = "dsp.py"
        let editedData = try JSONSerialization.data(
            withJSONObject: manifestDict,
            options: [.prettyPrinted]
        )
        try editedData.write(to: manifestURL)
        // Move the entry file to match.
        let oldScript = bundleURL.appendingPathComponent("process.py")
        let newScript = bundleURL.appendingPathComponent("dsp.py")
        try FileManager.default.moveItem(at: oldScript, to: newScript)

        // Cmd+S — should write the new source to `dsp.py` (per manifest),
        // not to the default `process.py`.
        try manager.savePreset(
            name: "CustomEntry",
            source: "# v2\n",
            language: .python
        )

        #expect(FileManager.default.fileExists(atPath: newScript.path),
               "Entry script at manifest-declared path must still exist")
        #expect(!FileManager.default.fileExists(atPath: oldScript.path),
               "Default-named entry script must NOT be recreated")
        let scriptContent = try String(contentsOf: newScript, encoding: .utf8)
        #expect(scriptContent == "# v2\n")
    }

    // MARK: - Modification Tracking

    @Test @MainActor func isModifiedTracking() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let source = "# original\n"
        let preset = try manager.savePreset(name: "Track Me", source: source)
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

        try manager.savePreset(name: "Conflict", source: "pass\n")
        let name = manager.uniqueName(baseName: "Conflict")
        #expect(name == "Conflict 2")
    }

    @Test @MainActor func uniqueNameMultipleConflicts() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.savePreset(name: "Effect", source: "pass\n")
        try manager.savePreset(name: "Effect 2", source: "pass\n")
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
            try manager.savePreset(name: "   ", source: "pass\n")
        }
    }

    @Test @MainActor func userPresetExistsCheck() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        #expect(!manager.userPresetExists(name: "Nope"))
        try manager.savePreset(name: "Exists", source: "pass\n")
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
            presetsURL: tempDir
        )

        #expect(FileManager.default.fileExists(atPath: tempDir.path),
               "PresetManager should create user presets directory")
    }

    // MARK: - Factory vs User Separation

    @Test @MainActor func factoryAndUserPresetsCanShareNames() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Save a user preset with the same name as a factory preset
        try manager.savePreset(name: "Tremolo (Python)", source: "# user tremolo\n")

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
        try manager.savePreset(name: "Alpha", source: script)

        let renamed = try manager.renamePreset(
            manager.presets.first(where: { $0.name == "Alpha" && !$0.isFactory })!,
            to: "Beta"
        )

        #expect(renamed.name == "Beta")
        #expect(renamed.id == "user:Beta")
        #expect(!manager.presets.contains(where: { $0.name == "Alpha" && !$0.isFactory }))
        #expect(manager.presets.contains(where: { $0.name == "Beta" && !$0.isFactory }))
        #expect(manager.loadSource(for: renamed) == script)
    }

    @Test @MainActor func renameReturnsNewPresetWithUpdatedIdentity() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.savePreset(name: "Alpha", source: "# alpha\n")

        let preset = manager.presets.first(where: { $0.name == "Alpha" && !$0.isFactory })!
        let renamed = try manager.renamePreset(preset, to: "Beta")

        #expect(renamed.name == "Beta")
        #expect(renamed.id == "user:Beta")
        #expect(!manager.presets.contains(where: { $0.name == "Alpha" && !$0.isFactory }))
        #expect(manager.presets.contains(where: { $0.name == "Beta" && !$0.isFactory }))
    }

    @Test @MainActor func renameCurrentPresetUpdatesCurrent() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "# active preset\n"
        let preset = try manager.savePreset(name: "Current", source: script)
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

        let preset = try manager.savePreset(name: "Same", source: "pass\n")
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

        let preset = try manager.savePreset(name: "Valid", source: "pass\n")
        #expect(throws: PresetManagerError.self) {
            try manager.renamePreset(preset, to: "   ")
        }
    }

    @Test @MainActor func renameToConflictingNameThrows() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.savePreset(name: "Existing", source: "pass\n")
        let preset = try manager.savePreset(name: "ToRename", source: "pass\n")

        #expect(throws: PresetManagerError.self) {
            try manager.renamePreset(preset, to: "Existing")
        }
    }

    @Test @MainActor func renamePreservesLanguage() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "RustEffect", source: "fn process() {}\n", language: .rust)
        let renamed = try manager.renamePreset(preset, to: "RenamedRust")

        #expect(renamed.language == .rust)
        #expect(renamed.id == "user:RenamedRust")
        #expect(manager.loadSource(for: renamed) == "fn process() {}\n")
    }

    @Test @MainActor func renameNonCurrentDoesNotAffectCurrent() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let presetA = try manager.savePreset(name: "A", source: "# a\n")
        let presetB = try manager.savePreset(name: "B", source: "# b\n")
        manager.setCurrentPreset(presetA, source: "# a\n")

        try manager.renamePreset(presetB, to: "C")

        #expect(manager.currentPreset?.id == presetA.id)
        #expect(manager.currentPreset?.name == "A")
    }

    // MARK: - Custom UI scaffolding

    @Test @MainActor func scaffoldCustomUIWritesIndexHTMLAndUpdatesManifest() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "ScaffoldTarget", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle for saved preset")
            return
        }
        #expect(!bundle.hasCustomUI, "Fresh user bundle should not advertise a custom UI")

        let indexURL = try manager.scaffoldCustomUI(for: bundle)

        #expect(FileManager.default.fileExists(atPath: indexURL.path),
                "Scaffold should produce ui/index.html")
        let html = try String(contentsOf: indexURL, encoding: .utf8)
        #expect(html.contains("<html>"), "Starter HTML should contain an <html> tag")

        // The bundle should now load with hasCustomUI == true because the
        // manifest was rewritten to declare the UI block.
        guard let reloaded = manager.loadBundle(for: preset) else {
            Issue.record("Bundle failed to reload after scaffolding")
            return
        }
        #expect(reloaded.hasCustomUI, "Manifest should now advertise the UI")
        #expect(reloaded.manifest.ui?.entryHTML == "ui/index.html")
    }

    @Test @MainActor func scaffoldCustomUIPreservesExistingIndexHTML() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "Preserve", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }

        // Drop a custom index.html in place BEFORE scaffolding. The helper
        // should leave it alone and just fix up the manifest.
        let uiDir = bundle.rootURL.appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: uiDir, withIntermediateDirectories: true)
        let preExisting = "<!-- author's work -->"
        try preExisting.write(
            to: uiDir.appendingPathComponent("index.html"),
            atomically: true, encoding: .utf8
        )

        _ = try manager.scaffoldCustomUI(for: bundle)

        let after = try String(contentsOf: uiDir.appendingPathComponent("index.html"), encoding: .utf8)
        #expect(after == preExisting, "Scaffold should not clobber a pre-existing index.html")
    }

    // MARK: - Bundle file helpers: create / rename / delete / duplicate

    @Test @MainActor func createBundleFileWritesTemplate() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "CreateFile", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }

        let url = try manager.createBundleFile(
            in: bundle, relativePath: "ui/style.css", template: .blankCSS
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("/* styles */"), "CSS template should be written")
    }

    @Test @MainActor func createBundleFileRejectsOutsideBundle() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "Guard", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }

        #expect(throws: PresetManager.BundleFileError.self) {
            _ = try manager.createBundleFile(
                in: bundle, relativePath: "../../escape.html", template: .empty
            )
        }
    }

    @Test @MainActor func createBundleFileRejectsExisting() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "Exists", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }

        _ = try manager.createBundleFile(
            in: bundle, relativePath: "notes.md", template: .empty
        )
        #expect(throws: PresetManager.BundleFileError.self) {
            _ = try manager.createBundleFile(
                in: bundle, relativePath: "notes.md", template: .empty
            )
        }
    }

    @Test @MainActor func createBundleFolderCreatesDirectory() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "Folder", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }

        let url = try manager.createBundleFolder(in: bundle, relativePath: "ui/assets")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        #expect(exists && isDir.boolValue, "Folder should exist and be a directory")
    }

    @Test @MainActor func renameBundleFileMovesFile() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "Rename", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }
        _ = try manager.createBundleFile(
            in: bundle, relativePath: "ui/a.css", template: .blankCSS
        )

        let result = try manager.renameBundleFile(
            in: bundle, from: "ui/a.css", to: "ui/b.css"
        )
        #expect(!FileManager.default.fileExists(atPath: result.oldURL.path))
        #expect(FileManager.default.fileExists(atPath: result.newURL.path))
        #expect(result.manifestURL == nil, "Renaming an unrelated file should not touch the manifest")
    }

    @Test @MainActor func renameEntryScriptUpdatesManifest() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "EntryRename", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }

        let result = try manager.renameBundleFile(
            in: bundle, from: "process.py", to: "dsp.py"
        )
        #expect(result.manifestURL != nil, "Entry-script rename should rewrite the manifest")

        guard let reloaded = manager.loadBundle(for: preset) else {
            Issue.record("Bundle failed to reload after rename")
            return
        }
        #expect(reloaded.manifest.entry == "dsp.py")
        #expect(FileManager.default.fileExists(atPath: reloaded.entryScriptURL.path))
    }

    @Test @MainActor func renameUIIndexHTMLUpdatesManifest() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(
            name: "UIRename", source: "pass\n", scaffoldUI: true
        )
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }
        #expect(bundle.hasCustomUI, "Scaffolded bundle should have a UI")

        let result = try manager.renameBundleFile(
            in: bundle, from: "ui/index.html", to: "ui/main.html"
        )
        #expect(result.manifestURL != nil)

        guard let reloaded = manager.loadBundle(for: preset) else {
            Issue.record("Bundle failed to reload")
            return
        }
        #expect(reloaded.manifest.ui?.entryHTML == "ui/main.html")
        #expect(reloaded.hasCustomUI, "UI entry rename should still point at an existing file")
    }

    @Test @MainActor func deleteBundleFileRemovesFile() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "DeleteTarget", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }
        let url = try manager.createBundleFile(
            in: bundle, relativePath: "ui/scratch.js", template: .blankJS
        )
        try manager.deleteBundleFile(in: bundle, relativePath: "ui/scratch.js")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test @MainActor func deleteBundleFileRejectsManifest() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "DeleteManifest", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }

        #expect(throws: PresetManager.BundleFileError.self) {
            try manager.deleteBundleFile(in: bundle, relativePath: "manifest.json")
        }
    }

    @Test @MainActor func deleteBundleFileRejectsEntryScript() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "DeleteEntry", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }

        #expect(throws: PresetManager.BundleFileError.self) {
            try manager.deleteBundleFile(in: bundle, relativePath: "process.py")
        }
    }

    @Test @MainActor func duplicateBundleFileAppendsSuffix() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "Dup", source: "pass\n")
        guard let bundle = manager.loadBundle(for: preset) else {
            Issue.record("Expected bundle")
            return
        }
        _ = try manager.createBundleFile(
            in: bundle, relativePath: "ui/theme.css", template: .blankCSS
        )

        let copy1 = try manager.duplicateBundleFile(in: bundle, relativePath: "ui/theme.css")
        #expect(copy1.lastPathComponent == "theme 2.css")

        // A second duplication of the ORIGINAL should produce "theme 3.css"
        // because "theme 2.css" now exists.
        let copy2 = try manager.duplicateBundleFile(in: bundle, relativePath: "ui/theme.css")
        #expect(copy2.lastPathComponent == "theme 3.css")
    }

    @Test @MainActor func duplicateFactoryBundleCreatesUserBundle() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Grab any factory bundle to fork — stereowidth is a known default.
        guard let factory = manager.presets.first(where: { $0.isFactory && $0.name.contains("Stereo") }),
              let sourceBundle = manager.loadBundle(for: factory) else {
            Issue.record("Expected a factory preset to fork")
            return
        }

        let forked = try manager.duplicateFactoryBundle(source: sourceBundle)
        #expect(forked.name.hasPrefix("Copy of "),
                "Forked bundle should be named 'Copy of <factory>'")
        #expect(forked.rootURL.path.hasPrefix(tempDir.path),
                "Forked bundle should live under the user Presets directory")
        #expect(FileManager.default.fileExists(atPath: forked.entryScriptURL.path))

        // And it should now show up in the preset list.
        let match = manager.presets.first(where: { $0.id == "user:\(forked.name)" })
        #expect(match != nil, "Forked bundle should appear in refreshPresets()")
    }

    // MARK: - Dirty-file tracking (§5 explicit-save model)

    @Test @MainActor func noteDirtyFileTracksURL() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "Dirty", source: "pass\n")
        manager.setCurrentPreset(preset, source: "pass\n")
        #expect(manager.dirtyFiles.isEmpty)
        #expect(!manager.hasPendingChanges, "Fresh preset should have no pending changes")

        let url = tempDir.appendingPathComponent("Dirty.cdp/ui/index.html")
        manager.noteDirtyFile(url)

        #expect(manager.dirtyFiles.contains(url))
        #expect(manager.hasPendingChanges,
                "hasPendingChanges should be true once a ui/* file is dirty")
    }

    @Test @MainActor func clearDirtyFilesResets() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "Clear", source: "pass\n")
        manager.setCurrentPreset(preset, source: "pass\n")
        manager.noteDirtyFile(tempDir.appendingPathComponent("Clear.cdp/ui/a.css"))
        #expect(manager.hasPendingChanges)

        manager.clearDirtyFiles()
        #expect(manager.dirtyFiles.isEmpty)
        #expect(!manager.hasPendingChanges)
    }

    @Test @MainActor func setCurrentPresetClearsDirtyFiles() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let a = try manager.savePreset(name: "A", source: "# a\n")
        let b = try manager.savePreset(name: "B", source: "# b\n")
        manager.setCurrentPreset(a, source: "# a\n")
        manager.noteDirtyFile(tempDir.appendingPathComponent("A.cdp/ui/x.css"))
        #expect(manager.hasPendingChanges)

        manager.setCurrentPreset(b, source: "# b\n")
        #expect(manager.dirtyFiles.isEmpty,
                "Switching presets should wipe the dirty set")
        #expect(!manager.hasPendingChanges)
    }

    @Test @MainActor func hasPendingChangesReactsToIsModified() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "Pending", source: "# v1\n")
        manager.setCurrentPreset(preset, source: "# v1\n")
        #expect(!manager.hasPendingChanges)

        manager.scriptDidChange(to: "# v2\n")
        #expect(manager.hasPendingChanges,
                "Entry-script modification alone should flip hasPendingChanges")

        manager.scriptDidChange(to: "# v1\n")
        #expect(!manager.hasPendingChanges)
    }

    // MARK: - savePreset(cloneFrom:) — factory fork path
    //
    // These exercise the branch used by MCP `save_preset` when the
    // current preset is a factory bundle with a custom UI: the new
    // user bundle should inherit the factory's UI + manifest, with
    // only the entry script overwritten by the provided source.

    @MainActor
    private static func makeFactoryLikeBundle(at root: URL) throws -> PresetBundle {
        let rootDir = root.appendingPathComponent("SourceFactory.cdp", isDirectory: true)
        let uiDir = rootDir.appendingPathComponent("ui", isDirectory: true)
        let assetsDir = uiDir.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        let manifest = """
        {
            "schemaVersion": 2,
            "entry": "process.py",
            "language": "python",
            "params": [
                { "name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log" }
            ],
            "ui": {
                "entryHTML": "ui/index.html",
                "width": 520,
                "height": 380,
                "fps": 30,
                "audioFrames": false
            },
            "meta": { "author": "Factory", "category": "filter" }
        }
        """
        try manifest.write(
            to: rootDir.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8
        )
        try "# original factory script\n".write(
            to: rootDir.appendingPathComponent("process.py"),
            atomically: true, encoding: .utf8
        )
        try "<!doctype html><html><body>factory UI</body></html>\n".write(
            to: uiDir.appendingPathComponent("index.html"),
            atomically: true, encoding: .utf8
        )
        try "body { background: black; }\n".write(
            to: assetsDir.appendingPathComponent("style.css"),
            atomically: true, encoding: .utf8
        )

        guard let bundle = PresetBundle.load(from: rootDir) else {
            throw TestError("Failed to load factory-like bundle from \(rootDir.path)")
        }
        return bundle
    }

    @Test @MainActor func savePresetWithCloneFromCopiesUITree() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }
        let sourceBundle = try Self.makeFactoryLikeBundle(at: tempDir)

        _ = try manager.savePreset(
            name: "Forked Preset",
            source: "# agent wrote this\n",
            language: .python,
            cloneFrom: sourceBundle
        )

        // The new bundle should contain the factory's ui/ subtree.
        let newBundleDir = manager.presetsURL
            .appendingPathComponent("Forked Preset.cdp", isDirectory: true)
        let uiIndexURL = newBundleDir.appendingPathComponent("ui/index.html")
        let assetCSSURL = newBundleDir.appendingPathComponent("ui/assets/style.css")
        #expect(FileManager.default.fileExists(atPath: uiIndexURL.path),
                "ui/index.html should be copied from the source factory bundle")
        #expect(FileManager.default.fileExists(atPath: assetCSSURL.path),
                "ui/assets/style.css should be copied from the source factory bundle")

        // Contents survived the copy verbatim.
        let copiedIndexHTML = try String(contentsOf: uiIndexURL, encoding: .utf8)
        #expect(copiedIndexHTML.contains("factory UI"),
                "ui/index.html contents should match the source bundle")
    }

    @Test @MainActor func savePresetWithCloneFromPreservesManifest() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }
        let sourceBundle = try Self.makeFactoryLikeBundle(at: tempDir)

        _ = try manager.savePreset(
            name: "Forked Preset",
            source: "# agent wrote this\n",
            language: .python,
            cloneFrom: sourceBundle
        )

        let newBundleDir = manager.presetsURL
            .appendingPathComponent("Forked Preset.cdp", isDirectory: true)
        let manifestURL = newBundleDir.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PresetManifest.self, from: manifestData)

        // Everything from the source manifest survives verbatim:
        // schemaVersion, params, ui block, meta.
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.params?.count == 1)
        #expect(manifest.params?.first?.name == "cutoff")
        #expect(manifest.ui?.width == 520)
        #expect(manifest.ui?.audioFrames == false)
        #expect(manifest.meta?.author == "Factory")

        // Entry script contents, however, are the new source — not the
        // factory's original — so the agent's edits are reflected.
        let scriptURL = newBundleDir.appendingPathComponent(manifest.entry)
        let scriptBody = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(scriptBody == "# agent wrote this\n")
    }

    @Test @MainActor func savePresetWithCloneFromRespectsExistingTarget() throws {
        // When the target user bundle already exists, the re-save branch
        // runs — existing manifest/ui stays as-is, only the entry script
        // is updated. `cloneFrom` must NOT overwrite the user's state.
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Seed an existing user bundle with its own UI.
        _ = try manager.savePreset(
            name: "Already Exists",
            source: "# original user\n",
            language: .python,
            scaffoldUI: true
        )
        let existingBundleDir = manager.presetsURL
            .appendingPathComponent("Already Exists.cdp", isDirectory: true)
        let existingIndexURL = existingBundleDir.appendingPathComponent("ui/index.html")
        try "<html>USER_ORIGINAL</html>".write(
            to: existingIndexURL, atomically: true, encoding: .utf8
        )

        // Build an unrelated factory-like bundle to attempt to clone
        // from — its UI should NOT land, because the target exists.
        let sourceBundle = try Self.makeFactoryLikeBundle(at: tempDir)

        _ = try manager.savePreset(
            name: "Already Exists",
            source: "# re-saved user\n",
            language: .python,
            cloneFrom: sourceBundle
        )

        // UI survived — not replaced by the factory's "factory UI" string.
        let finalIndexHTML = try String(contentsOf: existingIndexURL, encoding: .utf8)
        #expect(finalIndexHTML.contains("USER_ORIGINAL"),
                "re-save into an existing bundle must preserve its ui/index.html")
        #expect(!finalIndexHTML.contains("factory UI"),
                "cloneFrom must NOT overwrite an existing user bundle's ui/")

        // Entry script got the new content.
        let scriptURL = existingBundleDir.appendingPathComponent("process.py")
        let scriptBody = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(scriptBody == "# re-saved user\n",
                "re-save must update the entry script")
    }
}
