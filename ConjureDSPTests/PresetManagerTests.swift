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

    /// Factory presets that ship a `ui/index.html` AND declare a manifest.ui
    /// block must report `hasCustomUI == true`. Regression guard for the
    /// preset-browser palette badge — when this returns false, the browser's
    /// `paintpalette` SF Symbol disappears AND the main view's custom-UI
    /// toggle bar collapses to "Basic UI" with no toggle, both of which
    /// silently make exported preset UIs untestable from the host app.
    /// SVF (Python + Rust) are the canonical custom-UI factory presets;
    /// they were added with the cdp-xy pad and have shipped with a UI
    /// since they were promoted to factory.
    @Test @MainActor func factoryBundlesWithCustomUIReportHasCustomUI() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let svfNames = ["State Variable Filter (Python)", "State Variable Filter (Rust)"]
        for name in svfNames {
            guard let preset = manager.presets.first(where: { $0.name == name }) else {
                Issue.record("Missing factory preset '\(name)'")
                continue
            }
            guard let bundle = manager.loadBundle(for: preset) else {
                Issue.record("loadBundle returned nil for factory '\(name)' — Bundle.url(forResource:withExtension:subdirectory:) likely failed to resolve the .cdp directory")
                continue
            }
            #expect(bundle.manifest.ui != nil,
                   "\(name) manifest must declare a ui block (it ships ui/index.html)")
            #expect(bundle.uiIndexURL != nil,
                   "\(name) ui/index.html must resolve under the bundle root — got rootURL=\(bundle.rootURL.path)")
            #expect(bundle.hasCustomUI,
                   "\(name) must report hasCustomUI=true so the preset-browser palette badge + main-view toggle bar render correctly")
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

        let script = "def process(inputs, outputs, frame_count, sample_rate, _params, _transport, _telemetry):\n    pass\n"
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

        let script = "def process(inputs, outputs, frame_count, sample_rate, _params, _transport, _telemetry):\n    pass\n"
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

        let script = "def process(inputs, outputs, frame_count, sample_rate, _params, _transport, _telemetry):\n    pass\n"
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

    // MARK: - External file watcher

    /// Regression guard for the "Reload UI" toolbar button never appearing
    /// when a custom UI is added to the active bundle from outside the
    /// in-plugin flows (VS Code, Finder, `git checkout`, terminal `mv`).
    /// `currentBundle.hasCustomUI` drives that button's visibility, so the
    /// PresetManager must own a watcher on the active user bundle's root
    /// that calls `refreshPresets()` on any filesystem change.
    @Test @MainActor func currentBundleRefreshesWhenCustomUIAppearsExternally() async throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.savePreset(name: "WatcherTarget", source: "pass\n")
        manager.setCurrentPreset(preset, source: "pass\n")

        #expect(manager.currentBundle?.hasCustomUI == false,
               "Fresh user bundle should not advertise a custom UI yet")

        guard let bundleURL = preset.fileURL else {
            Issue.record("Saved preset missing fileURL")
            return
        }

        // Simulate an external editor: drop ui/index.html and patch
        // manifest.json to declare the ui block. No in-plugin path
        // (no save / scaffold / MCP write) — just raw FileManager writes.
        let uiDir = bundleURL.appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: uiDir, withIntermediateDirectories: true)
        try "<!doctype html><html><body>hi</body></html>".write(
            to: uiDir.appendingPathComponent("index.html"),
            atomically: true, encoding: .utf8
        )

        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        var manifestDict = try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)
        ) as! [String: Any]
        manifestDict["ui"] = [
            "entryHTML": "ui/index.html",
            "width": 400,
            "height": 200,
        ]
        try JSONSerialization.data(
            withJSONObject: manifestDict,
            options: [.prettyPrinted]
        ).write(to: manifestURL)

        // Poll the main runloop until the watcher fires. FSEventStream
        // *should* deliver within ~0.2s (its coalescing latency), but in
        // practice the kernel sometimes throttles to 1–2s under load,
        // so give it a generous deadline. Each `Task.sleep` yields the
        // main actor so the watcher's queued callback can drain.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if manager.currentBundle?.hasCustomUI == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(manager.currentBundle?.hasCustomUI == true,
               "Bundle watcher should have refreshed currentBundle after external UI files appeared")
    }

    // MARK: - Save As: duplicate semantics

    /// Save As must fork the source bundle's `ui/` tree, manifest.params,
    /// and any author assets — not silently scaffold a generic
    /// `<cdp-panel auto>` placeholder. Regression guard for the bug where
    /// `Save As` on a hand-rolled scope_test preset produced a new bundle
    /// with the starter HTML and lost every author edit.
    @Test @MainActor func saveAsDuplicatesSourceBundleUITree() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Author a source bundle by hand: scaffold UI, then drop a hand-rolled
        // index.html + an asset file + a populated manifest.params block.
        let source = try manager.savePreset(
            name: "SourcePreset",
            source: "# v1\n",
            language: .python,
            scaffoldUI: true
        )
        guard let sourceBundle = manager.loadBundle(for: source) else {
            Issue.record("Expected source bundle to load")
            return
        }
        let sourceRoot = sourceBundle.rootURL
        let sourceIndexURL = sourceRoot.appendingPathComponent("ui/index.html")
        let customIndex = "<!-- author's scope drawing --><canvas id=\"scope\"></canvas>"
        try customIndex.write(to: sourceIndexURL, atomically: true, encoding: .utf8)
        let sourceAssetURL = sourceRoot.appendingPathComponent("ui/assets/style.css")
        try FileManager.default.createDirectory(
            at: sourceAssetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "body { background: #0a0a0e; }".write(to: sourceAssetURL, atomically: true, encoding: .utf8)

        // Patch manifest.params + manifest.ui height so we can verify both
        // get carried over by the duplicate.
        let manifestURL = sourceRoot.appendingPathComponent("manifest.json")
        var manifestDict = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifestDict["params"] = [
            ["name": "Drive", "min": 0.0, "max": 24.0, "default": 6.0, "unit": "dB"],
            ["name": "Mix", "min": 0.0, "max": 1.0, "default": 0.5, "unit": ""],
        ]
        var uiBlock = manifestDict["ui"] as! [String: Any]
        uiBlock["height"] = 400
        manifestDict["ui"] = uiBlock
        try JSONSerialization.data(withJSONObject: manifestDict, options: [.prettyPrinted]).write(to: manifestURL)

        // Re-load so the duplicateFrom argument captures the edited manifest.
        guard let edited = manager.loadBundle(for: source) else {
            Issue.record("Expected edited source bundle to reload")
            return
        }

        // Save As — the scenario the user hit with scope_test.
        let dup = try manager.savePreset(
            name: "ForkedPreset",
            source: "# v2\n",
            language: .python,
            scaffoldUI: false,
            duplicateFrom: edited
        )

        guard let dupBundle = manager.loadBundle(for: dup) else {
            Issue.record("Expected forked bundle to load")
            return
        }
        let dupRoot = dupBundle.rootURL

        // The author's index.html must survive — not be replaced by the
        // generic `<cdp-panel auto>` starter.
        let dupIndexURL = dupRoot.appendingPathComponent("ui/index.html")
        let dupIndex = try String(contentsOf: dupIndexURL, encoding: .utf8)
        #expect(dupIndex == customIndex,
                "Save As must preserve author's ui/index.html, not scaffold a generic starter")

        // Asset directory and contents copied verbatim.
        let dupAssetURL = dupRoot.appendingPathComponent("ui/assets/style.css")
        let dupAsset = try String(contentsOf: dupAssetURL, encoding: .utf8)
        #expect(dupAsset == "body { background: #0a0a0e; }",
                "Save As must copy ui/assets/* from the source bundle")

        // manifest.params and manifest.ui customizations carried over.
        #expect(dupBundle.manifest.params?.count == 2,
                "Save As must carry manifest.params from source")
        #expect(dupBundle.manifest.params?.first?.name == "Drive")
        #expect(dupBundle.manifest.ui?.height == 400,
                "Save As must carry manifest.ui customizations from source")

        // Entry script reflects the editor's source, not the source bundle's.
        let dupScript = try String(
            contentsOf: dupRoot.appendingPathComponent("process.py"),
            encoding: .utf8
        )
        #expect(dupScript == "# v2\n",
                "Save As must overwrite the entry script with the editor's source")

        // Source bundle is left untouched.
        let srcStillThere = try String(contentsOf: sourceIndexURL, encoding: .utf8)
        #expect(srcStillThere == customIndex,
                "Save As must not mutate the source bundle")
    }

    /// When the editor's language differs from the source bundle's language
    /// (e.g. user opens a Rust preset, retypes it as Python, hits Save As),
    /// the duplicate's manifest.entry / manifest.language must follow the
    /// editor — and the stale entry script from the source language must
    /// not linger in the duplicate, otherwise the bundle has two competing
    /// entries on disk.
    @Test @MainActor func saveAsDuplicateAcrossLanguagesPatchesManifest() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let source = try manager.savePreset(
            name: "RustSource",
            source: "fn process() {}\n",
            language: .rust,
            scaffoldUI: true
        )
        guard let sourceBundle = manager.loadBundle(for: source) else {
            Issue.record("Expected source bundle")
            return
        }
        #expect(sourceBundle.manifest.entry == "process.rs")

        let dup = try manager.savePreset(
            name: "ForkedAsPython",
            source: "# python now\n",
            language: .python,
            scaffoldUI: false,
            duplicateFrom: sourceBundle
        )
        guard let dupBundle = manager.loadBundle(for: dup) else {
            Issue.record("Expected forked bundle to load")
            return
        }

        #expect(dupBundle.manifest.entry == "process.py",
                "Manifest.entry must follow the new language")
        #expect(dupBundle.manifest.language == ScriptLanguage.python.rawValue,
                "Manifest.language must follow the new language")

        // Old entry script must be gone — otherwise the bundle has two
        // potential entry scripts and the v1 fallback path could pick the
        // wrong one.
        let staleRustURL = dupBundle.rootURL.appendingPathComponent("process.rs")
        #expect(!FileManager.default.fileExists(atPath: staleRustURL.path),
                "Old-language entry script must be removed when changing languages")

        // ui/ tree still preserved across the language change.
        let dupIndexURL = dupBundle.rootURL.appendingPathComponent("ui/index.html")
        #expect(FileManager.default.fileExists(atPath: dupIndexURL.path),
                "ui/index.html must still be carried over across language changes")
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

    // MARK: - savePreset: fresh bundle, no implicit inheritance
    //
    // save_preset always produces a fresh user bundle. When the agent
    // wants to carry content over from another preset, it reads +
    // writes those files explicitly — the handler does not clone.

    @Test @MainActor func savePresetFromScratchDoesNotInheritFromCurrent() throws {
        // Seed an unrelated user bundle with its own UI. save_preset
        // with a different name must NOT pull anything from it.
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        _ = try manager.savePreset(
            name: "Existing", source: "# existing\n",
            language: .python, scaffoldUI: true
        )
        let existingUIURL = manager.presetsURL
            .appendingPathComponent("Existing.cdp/ui/index.html")
        try "<html>EXISTING_UI</html>".write(
            to: existingUIURL, atomically: true, encoding: .utf8
        )

        _ = try manager.savePreset(
            name: "Fresh", source: "# fresh\n",
            language: .python, scaffoldUI: false
        )
        let freshBundleDir = manager.presetsURL
            .appendingPathComponent("Fresh.cdp", isDirectory: true)
        let freshUIURL = freshBundleDir.appendingPathComponent("ui/index.html")

        #expect(!FileManager.default.fileExists(atPath: freshUIURL.path),
                "scaffoldUI=false with no inheritance must leave ui/ absent")

        let freshManifestURL = freshBundleDir.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: freshManifestURL)
        let manifest = try JSONDecoder().decode(PresetManifest.self, from: manifestData)
        #expect(manifest.ui == nil,
                "fresh bundle must not inherit a ui block")
        #expect((manifest.params?.isEmpty ?? true),
                "fresh bundle must not inherit params from any other preset")
    }

    // MARK: - syncManifestParamsFromKernel: cache of kernel metadata
    //
    // `manifest.params` is a CACHE of the kernel-extracted parameter
    // metadata, not an authoritative override. Every save and every
    // load-with-drift refreshes the cache from kernel reflection. The
    // sibling `_paramsNote` documents that contract in the file itself,
    // so an author who hand-edits the block sees a warning before their
    // change is silently overwritten on the next sync.
    //
    // This was a behavior change from the earlier (`updateManifestParams`)
    // implementation, which preserved an existing non-empty `params`
    // block. That preservation defended a hypothetical "narrow the
    // slider range via manifest hand-edit" workflow at the cost of a
    // real correctness bug: edits to PARAMS / params!() that ran via
    // `compile_and_run` left the manifest stale, and a subsequent UI
    // Cmd+S didn't re-sync — the bundle stayed on stale ranges across
    // every future load. See the task body in Asana
    // (1214586240091333) for the full drift sequence and rationale.

    @Test @MainActor func syncManifestParamsFromKernelWritesParamsBlock() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Save a fresh bundle the way the MCP path does — scaffold
        // the UI, leave the manifest's params block nil.
        _ = try manager.savePreset(
            name: "MirrorTarget", source: "# v1\n",
            language: .python, scaffoldUI: true
        )
        let preset = try #require(
            manager.presets.first(where: { $0.name == "MirrorTarget" })
        )
        let bundle = try #require(manager.loadBundle(for: preset))
        #expect((bundle.manifest.params?.isEmpty ?? true),
                "Precondition: fresh bundle has no params block")

        // Mirror two simulated kernel-extracted params into the manifest.
        let cutoff = PresetManifest.ParamDecl(
            name: "Cutoff", key: nil, min: 20, max: 20000, default: 1000,
            unit: "Hz", curve: "log", style: nil, options: nil
        )
        let resonance = PresetManifest.ParamDecl(
            name: "Resonance", key: nil, min: 0.5, max: 10, default: 0.707,
            unit: nil, curve: nil, style: nil, options: nil
        )
        let didWrite = try manager.syncManifestParamsFromKernel(
            for: bundle, params: [cutoff, resonance]
        )
        #expect(didWrite, "First mirror should write")

        // Re-load the bundle from disk and verify the params landed.
        let reloaded = try #require(manager.loadBundle(for: preset))
        let params = try #require(reloaded.manifest.params)
        #expect(params.count == 2)
        #expect(params[0].name == "Cutoff")
        #expect(params[0].curve == "log")
        #expect(params[0].unit == "Hz")
        #expect(params[1].name == "Resonance")
        #expect(params[1].default == 0.707)
        // Empty unit must round-trip as nil for compact JSON.
        #expect(params[1].unit == nil)
    }

    /// Pinned regression: an authored `params` block (e.g. someone who
    /// hand-wrote `style: "choice"` + `options`) is OVERWRITTEN by a
    /// subsequent kernel-extracted reflection. This is intentional —
    /// kernel metadata is the source of truth, and the `_paramsNote`
    /// sibling field documents that contract in the manifest itself so
    /// an author who hand-edits the block sees a warning before the
    /// next sync silently overwrites it.
    ///
    /// If a future maintainer reads `syncManifestParamsFromKernel` and
    /// thinks "this looks unsafe — let me put back a guard against
    /// overwriting authored params", this test should fail and surface
    /// the rationale before they revert.
    @Test @MainActor func syncManifestParamsFromKernelAlwaysOverwritesAuthoredBlock() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Build a bundle that has an explicitly-authored params block
        // including choice metadata the kernel reflection won't know
        // about (`style: "choice"` + options).
        _ = try manager.savePreset(
            name: "ExplicitParams", source: "# v1\n",
            language: .python, scaffoldUI: true
        )
        let preset = try #require(
            manager.presets.first(where: { $0.name == "ExplicitParams" })
        )
        var bundle = try #require(manager.loadBundle(for: preset))

        let authored = PresetManifest.ParamDecl(
            name: "Mode", key: nil, min: 0, max: 2, default: 0,
            unit: nil, curve: nil, style: "choice",
            options: ["Low", "Mid", "High"]
        )
        let firstWrite = try manager.syncManifestParamsFromKernel(
            for: bundle, params: [authored]
        )
        #expect(firstWrite)

        // Now reload and overwrite with a kernel reflection that
        // LACKS the choice metadata. New behavior: this MUST clobber
        // the author. (Old behavior: this was a no-op, which masked
        // real drift bugs.)
        bundle = try #require(manager.loadBundle(for: preset))
        let kernelReflection = PresetManifest.ParamDecl(
            name: "Mode", key: nil, min: 0, max: 2, default: 0,
            unit: nil, curve: nil, style: nil, options: nil
        )
        let secondWrite = try manager.syncManifestParamsFromKernel(
            for: bundle, params: [kernelReflection]
        )
        #expect(secondWrite, "Sync must always overwrite — manifest.params is a cache, not an override")

        // Confirm the kernel reflection won; choice metadata is gone.
        let reloaded = try #require(manager.loadBundle(for: preset))
        let params = try #require(reloaded.manifest.params)
        #expect(params.count == 1)
        #expect(params[0].style == nil, "Authored style: 'choice' must have been overwritten")
        #expect(params[0].options == nil, "Authored options must have been overwritten")
    }

    /// Empty-input semantics: when the script removes its PARAMS dict,
    /// the next sync must clear the manifest's `params` block (and the
    /// sibling `_paramsNote`). The old behavior short-circuited on
    /// empty input and left a stale block on disk forever.
    @Test @MainActor func syncManifestParamsFromKernelClearsStaleBlockOnEmptyInput() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        // Set up a bundle that has a params block (the typical
        // post-save state for a preset whose script declares PARAMS).
        _ = try manager.savePreset(
            name: "WasParams", source: "# v1\n",
            language: .python, scaffoldUI: true
        )
        let preset = try #require(
            manager.presets.first(where: { $0.name == "WasParams" })
        )
        var bundle = try #require(manager.loadBundle(for: preset))
        let original = PresetManifest.ParamDecl(
            name: "Gain", key: nil, min: -24, max: 12, default: 0,
            unit: "dB", curve: nil, style: nil, options: nil
        )
        _ = try manager.syncManifestParamsFromKernel(
            for: bundle, params: [original]
        )

        // Confirm the params block AND _paramsNote landed on disk.
        bundle = try #require(manager.loadBundle(for: preset))
        #expect(bundle.manifest.params?.count == 1)
        #expect(bundle.manifest.paramsNote != nil)

        // Now sync with empty input — the script removed its PARAMS
        // dict. The manifest must clear both fields.
        let didWrite = try manager.syncManifestParamsFromKernel(
            for: bundle, params: []
        )
        #expect(didWrite, "Clearing a stale block counts as a write")

        let reloaded = try #require(manager.loadBundle(for: preset))
        #expect(reloaded.manifest.params == nil,
                "Stale params block must be cleared")
        #expect(reloaded.manifest.paramsNote == nil,
                "Stale _paramsNote must be cleared alongside params")

        // A second empty-input sync against the now-clean manifest
        // must be a no-op — keeps `git status` clean and avoids
        // spurious commits on every load of a paramless script.
        let secondDidWrite = try manager.syncManifestParamsFromKernel(
            for: reloaded, params: []
        )
        #expect(!secondDidWrite, "Empty input on already-clean manifest must not write")
    }

    /// Pinned regression: hand-edited top-level fields outside
    /// `PresetManifest`'s schema (e.g., `"metadata": "asdf"` typed in
    /// Monaco) survive a sync. A real user incident — typing
    /// `"metadata": "asdf"` and saving the script silently dropped the
    /// field on the next sync because the old Codable round-trip
    /// ignored unknown keys on decode and omitted them on re-encode.
    /// Switching to JSON-tree mutation keeps them in place.
    @Test @MainActor func syncManifestParamsFromKernelPreservesUnknownTopLevelFields() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        _ = try manager.savePreset(
            name: "UnknownFieldTarget", source: "# v1\n",
            language: .python, scaffoldUI: true
        )
        let preset = try #require(
            manager.presets.first(where: { $0.name == "UnknownFieldTarget" })
        )
        let bundle = try #require(manager.loadBundle(for: preset))
        let manifestURL = bundle.rootURL
            .appendingPathComponent(PresetManifest.filename)

        // Hand-add an unknown top-level field, the way an author might
        // by editing manifest.json in Monaco.
        var raw = try #require(
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)))
                as? [String: Any]
        )
        raw["metadata"] = "asdf"
        raw["customAuthorTag"] = ["nested": "value"]
        try JSONSerialization.data(
            withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]
        ).write(to: manifestURL)

        // Now sync params — this used to drop the unknown fields via
        // the Codable round-trip.
        let cutoff = PresetManifest.ParamDecl(
            name: "Cutoff", key: nil, min: 20, max: 20000, default: 1000,
            unit: "Hz", curve: "log", style: nil, options: nil
        )
        _ = try manager.syncManifestParamsFromKernel(
            for: bundle, params: [cutoff]
        )

        // Re-read raw JSON and confirm the unknown fields survived
        // alongside the new params block.
        let after = try #require(
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)))
                as? [String: Any]
        )
        #expect(after["metadata"] as? String == "asdf",
                "Unknown top-level field `metadata` must survive the sync")
        #expect(after["customAuthorTag"] as? [String: String] == ["nested": "value"],
                "Unknown nested field must also survive")
        #expect((after["params"] as? [Any])?.count == 1,
                "Sync should still have written the new params block")
        #expect(after["_paramsNote"] != nil,
                "Sync should still have written the _paramsNote sibling")
    }

    /// Idempotency: re-syncing the same params on a manifest that
    /// already matches must NOT write. Without this guard, every
    /// `persistManifest=true` reload of a non-drifting preset would
    /// emit a spurious `manifestDriftCorrected` event and an empty
    /// git-commit attempt — every Run / save would queue a no-op
    /// commit.
    @Test @MainActor func syncManifestParamsFromKernelIsIdempotent() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        _ = try manager.savePreset(
            name: "IdempotentTarget", source: "# v1\n",
            language: .python, scaffoldUI: true
        )
        let preset = try #require(
            manager.presets.first(where: { $0.name == "IdempotentTarget" })
        )
        var bundle = try #require(manager.loadBundle(for: preset))

        let cutoff = PresetManifest.ParamDecl(
            name: "Cutoff", key: nil, min: 20, max: 20000, default: 1000,
            unit: "Hz", curve: "log", style: nil, options: nil
        )
        let firstWrite = try manager.syncManifestParamsFromKernel(
            for: bundle, params: [cutoff]
        )
        #expect(firstWrite, "First sync should write")

        bundle = try #require(manager.loadBundle(for: preset))
        let secondWrite = try manager.syncManifestParamsFromKernel(
            for: bundle, params: [cutoff]
        )
        #expect(!secondWrite, "Second sync with identical params must be a no-op")
    }

    /// `_paramsNote` round-trips through `PresetManifest`'s Codable —
    /// the JSON key is `_paramsNote` (custom CodingKeys), the Swift
    /// property is `paramsNote`. The fixed warning string sorts
    /// alphabetically just above `params` in the pretty-printed output.
    @Test @MainActor func syncManifestParamsFromKernelWritesParamsNoteOnNonEmpty() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        _ = try manager.savePreset(
            name: "NoteTarget", source: "# v1\n",
            language: .python, scaffoldUI: true
        )
        let preset = try #require(
            manager.presets.first(where: { $0.name == "NoteTarget" })
        )
        let bundle = try #require(manager.loadBundle(for: preset))

        let gain = PresetManifest.ParamDecl(
            name: "Gain", key: nil, min: -24, max: 12, default: 0,
            unit: "dB", curve: nil, style: nil, options: nil
        )
        _ = try manager.syncManifestParamsFromKernel(
            for: bundle, params: [gain]
        )

        // Round-trip the manifest through Codable (loadBundle uses
        // JSONDecoder internally) and verify the note shows up.
        let reloaded = try #require(manager.loadBundle(for: preset))
        #expect(reloaded.manifest.paramsNote == PresetManager.kernelDerivedParamsNote,
                "Every non-empty sync must write the fixed warning string")

        // Verify the on-disk JSON uses the underscore-prefixed key
        // and that it sorts above `params` (the encoder uses
        // `.sortedKeys`, and `_` < `p` lexicographically).
        let manifestPath = bundle.rootURL
            .appendingPathComponent(PresetManifest.filename)
        let jsonString = try String(contentsOf: manifestPath, encoding: .utf8)
        #expect(jsonString.contains("\"_paramsNote\""),
                "JSON key must use the underscore-prefixed `_paramsNote` form")
        if let noteRange = jsonString.range(of: "\"_paramsNote\""),
           let paramsRange = jsonString.range(of: "\"params\"") {
            #expect(noteRange.lowerBound < paramsRange.lowerBound,
                    "`_paramsNote` must sort above `params` so it reads as a header to that block")
        } else {
            Issue.record("Expected both `_paramsNote` and `params` keys in the manifest")
        }
    }

    // The ParamDecl(from: ParamMetadata) round-trip lives in
    // PresetManifest+AU.swift, which is intentionally not in this
    // test target (the AU type ConjureDSPExtensionAudioUnit.ParamMetadata
    // would create a circular link). The conversion is exercised
    // end-to-end via the MCP save_preset integration test instead.
}
