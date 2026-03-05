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
            let appexURL = plugInsURL.appendingPathComponent("BearBoneExtension.appex")
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
        #expect(factory.count == 44)
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
            let source = manager.loadSource(for: preset)
            #expect(source != nil, "Should load source for factory preset \(preset.name)")
            if preset.language == .rust {
                #expect(source!.contains("fn process"), "Rust factory preset \(preset.name) should contain fn process")
            } else {
                #expect(source!.contains("def process"), "Python factory preset \(preset.name) should contain def process")
            }
        }
    }

    @Test @MainActor func factoryPresetsHaveCorrectLanguage() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let factory = manager.presets.filter(\.isFactory)
        let rustPresets = factory.filter { $0.language == .rust }
        let pythonPresets = factory.filter { $0.language == .python }
        #expect(rustPresets.count == 22, "Should have exactly 22 Rust factory presets")
        #expect(pythonPresets.count == 22, "Should have exactly 22 Python factory presets")
    }

    // MARK: - User Preset CRUD

    @Test @MainActor func saveAndLoadUserPreset() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "def process(inputs, outputs, frame_count, sample_rate):\n    pass\n"
        let preset = try manager.saveUserPreset(name: "My Effect", source: script)

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
        let preset = try manager.saveUserPreset(name: "My Rust Effect", source: script, language: .rust)

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
        try manager.saveUserPreset(name: "Test Preset", source: script)

        let userPresets = manager.presets.filter { !$0.isFactory }
        #expect(userPresets.count == 1)
        #expect(userPresets[0].name == "Test Preset")
    }

    @Test @MainActor func deleteUserPreset() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let script = "pass\n"
        let preset = try manager.saveUserPreset(name: "To Delete", source: script)
        #expect(manager.presets.contains(where: { $0.id == preset.id }))

        try manager.deleteUserPreset(preset)
        #expect(!manager.presets.contains(where: { $0.id == preset.id }))
    }

    @Test @MainActor func deleteCurrentPresetClearsCurrent() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        let preset = try manager.saveUserPreset(name: "Active", source: "pass\n")
        manager.setCurrentPreset(preset, source: "pass\n")
        #expect(manager.currentPreset?.id == preset.id)

        try manager.deleteUserPreset(preset)
        #expect(manager.currentPreset == nil)
        #expect(manager.isModified == false)
    }

    @Test @MainActor func overwriteExistingUserPreset() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.saveUserPreset(name: "Evolving", source: "# version 1\n")
        try manager.saveUserPreset(name: "Evolving", source: "# version 2\n")

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
        let preset = try manager.saveUserPreset(name: "Track Me", source: source)
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

        try manager.saveUserPreset(name: "Conflict", source: "pass\n")
        let name = manager.uniqueName(baseName: "Conflict")
        #expect(name == "Conflict 2")
    }

    @Test @MainActor func uniqueNameMultipleConflicts() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        try manager.saveUserPreset(name: "Effect", source: "pass\n")
        try manager.saveUserPreset(name: "Effect 2", source: "pass\n")
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
            try manager.saveUserPreset(name: "   ", source: "pass\n")
        }
    }

    @Test @MainActor func userPresetExistsCheck() throws {
        let (manager, tempDir) = try Self.makeManager()
        defer { Self.cleanup(tempDir) }

        #expect(!manager.userPresetExists(name: "Nope"))
        try manager.saveUserPreset(name: "Exists", source: "pass\n")
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

        #expect(manager.presets.count == 44, "Should only have factory presets")
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
        try manager.saveUserPreset(name: "Tremolo (Python)", source: "# user tremolo\n")

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
}
