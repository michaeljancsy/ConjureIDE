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
        #expect(renamed.id == "user:Beta.py")
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
        #expect(renamed.id == "user:Beta.py")
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
        #expect(renamed.id == "user:RenamedRust.rs")
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
}
