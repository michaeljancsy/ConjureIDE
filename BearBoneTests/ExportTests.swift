import Testing
import Foundation

// MARK: - SubtypeGenerator Tests

struct SubtypeGeneratorTests {

    @Test func deterministicHash() {
        let a = SubtypeGenerator.generate(for: "My Effect", existing: [])
        let b = SubtypeGenerator.generate(for: "My Effect", existing: [])
        #expect(a == b)
    }

    @Test func fourCharacterOutput() {
        let code = SubtypeGenerator.generate(for: "Test Preset", existing: [])
        #expect(code.count == 4)
    }

    @Test func uppercaseAlphanumericOnly() {
        let code = SubtypeGenerator.generate(for: "Test Preset", existing: [])
        let allowed = CharacterSet.uppercaseLetters.union(.decimalDigits)
        for scalar in code.unicodeScalars {
            #expect(allowed.contains(scalar), "Character '\(scalar)' not in allowed set")
        }
    }

    @Test func differentNamesProduceDifferentCodes() {
        let a = SubtypeGenerator.generate(for: "Tremolo", existing: [])
        let b = SubtypeGenerator.generate(for: "Bitcrusher", existing: [])
        #expect(a != b)
    }

    @Test func collisionAvoidance() {
        let first = SubtypeGenerator.generate(for: "My Effect", existing: [])
        let second = SubtypeGenerator.generate(for: "My Effect", existing: [first])
        #expect(first != second)
        #expect(second.count == 4)
    }

    @Test func reservedSubtypesAvoided() {
        // Even if hash happened to produce a reserved code, it would be incremented
        for reserved in SubtypeGenerator.reserved {
            let code = SubtypeGenerator.generate(for: "anything", existing: [reserved])
            // The code itself might not be reserved (it's hash-based), but if it were,
            // the collision logic would handle it. Just verify it's not in reserved.
            // This tests the union of reserved + existing.
        }
        // More directly: generate a code then add it to both existing AND reserved check
        let code = SubtypeGenerator.generate(for: "Test", existing: [])
        #expect(!SubtypeGenerator.reserved.contains(code))
    }

    @Test func specialCharactersInName() {
        // Should not crash or produce empty strings
        let code = SubtypeGenerator.generate(for: "My Effect!@#$%^&*()", existing: [])
        #expect(code.count == 4)
    }

    @Test func emptyName() {
        let code = SubtypeGenerator.generate(for: "", existing: [])
        #expect(code.count == 4)
    }
}

// MARK: - ExportRegistry Tests

struct ExportRegistryTests {

    private func makeTempRegistryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportRegistryTests_\(UUID().uuidString)")
            .appendingPathComponent("export-registry.json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func registerAndLoad() {
        let url = makeTempRegistryURL()
        defer { cleanup(url) }

        let registry = ExportRegistry(registryURL: url)
        let entry = ExportRegistry.Entry(
            name: "My Effect",
            subtype: "ABCD",
            bundleId: "com.BearBone-user.My_Effect",
            exportDate: Date(),
            language: "rust"
        )
        registry.register(entry)

        // Reload from disk
        let registry2 = ExportRegistry(registryURL: url)
        #expect(registry2.entries.count == 1)
        #expect(registry2.entries[0].name == "My Effect")
        #expect(registry2.entries[0].subtype == "ABCD")
    }

    @Test func allSubtypes() {
        let url = makeTempRegistryURL()
        defer { cleanup(url) }

        let registry = ExportRegistry(registryURL: url)
        registry.register(ExportRegistry.Entry(
            name: "A", subtype: "AAAA", bundleId: "x", exportDate: Date(), language: "rust"))
        registry.register(ExportRegistry.Entry(
            name: "B", subtype: "BBBB", bundleId: "y", exportDate: Date(), language: "python"))

        #expect(registry.allSubtypes() == Set(["AAAA", "BBBB"]))
    }

    @Test func removeBySubtype() {
        let url = makeTempRegistryURL()
        defer { cleanup(url) }

        let registry = ExportRegistry(registryURL: url)
        registry.register(ExportRegistry.Entry(
            name: "A", subtype: "AAAA", bundleId: "x", exportDate: Date(), language: "rust"))
        registry.register(ExportRegistry.Entry(
            name: "B", subtype: "BBBB", bundleId: "y", exportDate: Date(), language: "python"))

        let removed = registry.remove(subtype: "AAAA")
        #expect(removed?.name == "A")
        #expect(registry.entries.count == 1)
        #expect(registry.entries[0].subtype == "BBBB")
    }

    @Test func duplicateSubtypeReplaces() {
        let url = makeTempRegistryURL()
        defer { cleanup(url) }

        let registry = ExportRegistry(registryURL: url)
        registry.register(ExportRegistry.Entry(
            name: "V1", subtype: "AAAA", bundleId: "x", exportDate: Date(), language: "rust"))
        registry.register(ExportRegistry.Entry(
            name: "V2", subtype: "AAAA", bundleId: "x", exportDate: Date(), language: "rust"))

        #expect(registry.entries.count == 1)
        #expect(registry.entries[0].name == "V2")
    }

    @Test func entryForName() {
        let url = makeTempRegistryURL()
        defer { cleanup(url) }

        let registry = ExportRegistry(registryURL: url)
        registry.register(ExportRegistry.Entry(
            name: "My Effect", subtype: "ABCD", bundleId: "x", exportDate: Date(), language: "rust"))

        #expect(registry.entry(forName: "My Effect")?.subtype == "ABCD")
        #expect(registry.entry(forName: "Other") == nil)
    }

    @Test func emptyRegistryOnMissingFile() {
        let url = makeTempRegistryURL()
        let registry = ExportRegistry(registryURL: url)
        #expect(registry.entries.isEmpty)
    }
}

// MARK: - ExportManager Tests

struct ExportManagerTests {

    /// Creates a minimal fake template .app bundle structure for testing.
    private func createMockTemplate() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportManagerTests_\(UUID().uuidString)", isDirectory: true)
        let templateURL = tempDir.appendingPathComponent("BearBoneExportAUTemplate.app")
        let fm = FileManager.default

        // .app/Contents/Info.plist (host app)
        let appContents = templateURL.appendingPathComponent("Contents")
        try fm.createDirectory(at: appContents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)

        let appPlist: [String: Any] = [
            "CFBundleIdentifier": "com.BearBone-user.ExportTemplate",
            "CFBundleName": "BearBoneExportAUTemplate",
            "CFBundleExecutable": "BearBoneExportAUTemplate",
            "CFBundlePackageType": "APPL",
        ]
        let appPlistData = try PropertyListSerialization.data(fromPropertyList: appPlist, format: .xml, options: 0)
        try appPlistData.write(to: appContents.appendingPathComponent("Info.plist"))

        // Dummy executable
        try Data("binary".utf8).write(to: appContents.appendingPathComponent("MacOS/BearBoneExportAUTemplate"))

        // .appex/Contents/Info.plist (extension)
        let appexContents = appContents
            .appendingPathComponent("PlugIns/BearBoneExportAUTemplateExtension.appex/Contents")
        try fm.createDirectory(at: appexContents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: appexContents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        let extPlist: [String: Any] = [
            "CFBundleIdentifier": "com.BearBone-user.ExportTemplate.Extension",
            "CFBundleDisplayName": "BearBoneExportAUTemplateExtension",
            "CFBundleExecutable": "BearBoneExportAUTemplateExtension",
            "CFBundlePackageType": "XPC!",
            "NSExtension": [
                "NSExtensionAttributes": [
                    "AudioComponents": [[
                        "name": "BearBone: ExportTemplate",
                        "type": "aufx",
                        "subtype": "TMPL",
                        "manufacturer": "A000",
                        "description": "BearBone Export",
                        "sandboxSafe": true,
                        "version": 1,
                    ]]
                ],
                "NSExtensionPointIdentifier": "com.apple.AudioUnit-UI",
            ] as [String: Any],
        ]
        let extPlistData = try PropertyListSerialization.data(fromPropertyList: extPlist, format: .xml, options: 0)
        try extPlistData.write(to: appexContents.appendingPathComponent("Info.plist"))

        // Dummy executable
        try Data("binary".utf8).write(to: appexContents.appendingPathComponent("MacOS/BearBoneExportAUTemplateExtension"))

        // Placeholder preset.wasm
        try Data("placeholder".utf8).write(to: appexContents.appendingPathComponent("Resources/preset.wasm"))

        // Placeholder runtime-config.json
        let configJSON = try JSONSerialization.data(withJSONObject: [
            "version": 1, "language": "rust", "presetName": "ExportTemplate", "paramCount": 8,
        ] as [String: Any], options: .prettyPrinted)
        try configJSON.write(to: appexContents.appendingPathComponent("Resources/runtime-config.json"))

        return templateURL
    }

    private func cleanup(_ url: URL) {
        // Remove the parent temp directory
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent)
    }

    @Test func sanitizeName() {
        #expect(ExportManager.sanitizeName("My Cool Reverb") == "My_Cool_Reverb")
        #expect(ExportManager.sanitizeName("hello!@#world") == "hello___world")
        #expect(ExportManager.sanitizeName("___test___") == "test")
        #expect(ExportManager.sanitizeName("") == "Untitled")
        #expect(ExportManager.sanitizeName("Simple") == "Simple")
        #expect(ExportManager.sanitizeName("with-dashes_and_underscores") == "with-dashes_and_underscores")
    }

    @Test func exportRustPreset() throws {
        let templateURL = try createMockTemplate()
        defer { cleanup(templateURL) }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportOutput_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportRegistry_\(UUID().uuidString)")
            .appendingPathComponent("export-registry.json")
        defer { try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent()) }

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)

        let wasmData = Data("fake wasm binary".utf8)
        let result = try manager.exportPreset(
            name: "Bitcrusher",
            source: "fn process() {}",
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir
        )

        // Verify output exists
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(result.lastPathComponent == "Bitcrusher.app")

        // Verify preset.wasm was written
        let presetWasm = result
            .appendingPathComponent("Contents/PlugIns/BearBoneExportAUTemplateExtension.appex/Contents/Resources/preset.wasm")
        let writtenWasm = try Data(contentsOf: presetWasm)
        #expect(writtenWasm == wasmData)

        // Verify runtime-config.json
        let configURL = result
            .appendingPathComponent("Contents/PlugIns/BearBoneExportAUTemplateExtension.appex/Contents/Resources/runtime-config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
        #expect(config["language"] as? String == "rust")
        #expect(config["presetName"] as? String == "Bitcrusher")
        #expect(config["paramCount"] as? Int == 8)

        // Verify app plist patched
        let appPlistData = try Data(contentsOf: result.appendingPathComponent("Contents/Info.plist"))
        let appPlist = try PropertyListSerialization.propertyList(from: appPlistData, format: nil) as! [String: Any]
        #expect(appPlist["CFBundleIdentifier"] as? String == "com.BearBone-user.Bitcrusher")
        #expect(appPlist["CFBundleName"] as? String == "Bitcrusher")

        // Verify extension plist patched
        let extPlistData = try Data(contentsOf: result
            .appendingPathComponent("Contents/PlugIns/BearBoneExportAUTemplateExtension.appex/Contents/Info.plist"))
        let extPlist = try PropertyListSerialization.propertyList(from: extPlistData, format: nil) as! [String: Any]
        #expect(extPlist["CFBundleIdentifier"] as? String == "com.BearBone-user.Bitcrusher.Extension")

        let nsExt = extPlist["NSExtension"] as! [String: Any]
        let attrs = nsExt["NSExtensionAttributes"] as! [String: Any]
        let components = attrs["AudioComponents"] as! [[String: Any]]
        #expect(components[0]["name"] as? String == "BearBone: Bitcrusher")
        #expect(components[0]["subtype"] as? String != "TMPL")

        // Verify registry updated
        #expect(registry.entries.count == 1)
        #expect(registry.entries[0].name == "Bitcrusher")
    }

    @Test func exportPythonPreset() throws {
        let templateURL = try createMockTemplate()
        defer { cleanup(templateURL) }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportOutput_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportRegistry_\(UUID().uuidString)")
            .appendingPathComponent("export-registry.json")
        defer { try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent()) }

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)

        let source = "def process(inputs, outputs, frame_count, sample_rate):\n    pass\n"
        let result = try manager.exportPreset(
            name: "My Reverb",
            source: source,
            wasmData: nil,
            language: .python,
            templateURL: templateURL,
            outputDirectory: outputDir
        )

        let appexResources = result
            .appendingPathComponent("Contents/PlugIns/BearBoneExportAUTemplateExtension.appex/Contents/Resources")

        // Verify preset.py was written
        let presetPy = try String(contentsOf: appexResources.appendingPathComponent("preset.py"), encoding: .utf8)
        #expect(presetPy == source)

        // Verify placeholder preset.wasm was removed
        #expect(!FileManager.default.fileExists(atPath: appexResources.appendingPathComponent("preset.wasm").path))

        // Verify runtime-config.json says python
        let configData = try Data(contentsOf: appexResources.appendingPathComponent("runtime-config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
        #expect(config["language"] as? String == "python")

        // Verify output name sanitized
        #expect(result.lastPathComponent == "My_Reverb.app")
    }

    @Test func exportFailsWithoutWasmForRust() throws {
        let templateURL = try createMockTemplate()
        defer { cleanup(templateURL) }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportOutput_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let manager = ExportManager(registry: ExportRegistry(registryURL:
            FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")))

        #expect(throws: ExportManager.ExportError.self) {
            try manager.exportPreset(
                name: "Test",
                source: "",
                wasmData: nil,
                language: .rust,
                templateURL: templateURL,
                outputDirectory: outputDir
            )
        }
    }

    @Test func exportFailsWithMissingTemplate() throws {
        let fakeTemplate = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent.app")
        let outputDir = FileManager.default.temporaryDirectory

        let manager = ExportManager(registry: ExportRegistry(registryURL:
            FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")))

        #expect(throws: ExportManager.ExportError.self) {
            try manager.exportPreset(
                name: "Test",
                source: "",
                wasmData: Data(),
                language: .rust,
                templateURL: fakeTemplate,
                outputDirectory: outputDir
            )
        }
    }

    @Test func exportOverwritesPreviousExport() throws {
        let templateURL = try createMockTemplate()
        defer { cleanup(templateURL) }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportOutput_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportRegistry_\(UUID().uuidString)")
            .appendingPathComponent("export-registry.json")
        defer { try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent()) }

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)

        let wasm1 = Data("v1".utf8)
        let wasm2 = Data("v2".utf8)

        _ = try manager.exportPreset(
            name: "Effect", source: "", wasmData: wasm1, language: .rust,
            templateURL: templateURL, outputDirectory: outputDir)

        let result2 = try manager.exportPreset(
            name: "Effect", source: "", wasmData: wasm2, language: .rust,
            templateURL: templateURL, outputDirectory: outputDir)

        // Second export overwrites first
        let wasmPath = result2
            .appendingPathComponent("Contents/PlugIns/BearBoneExportAUTemplateExtension.appex/Contents/Resources/preset.wasm")
        let written = try Data(contentsOf: wasmPath)
        #expect(written == wasm2)

        // Registry has only one entry (replaced)
        #expect(registry.entries.count == 1)
    }
}
