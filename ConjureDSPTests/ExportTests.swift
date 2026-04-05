import Testing
import Foundation
import AudioToolbox

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
            bundleId: "com.ConjureDSP-user.My_Effect",
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

    /// Creates a minimal fake template .app, zips it, and returns the .zip URL.
    /// ExportManager.exportPreset expects a .zip (not a raw .app) because
    /// PluginKit would discover a raw .appex and register it.
    private func createMockTemplate() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportManagerTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let appDir = tempDir.appendingPathComponent("ConjureDSPExportAUTemplate.app")
        let fm = FileManager.default

        // .app/Contents/Info.plist (host app)
        let appContents = appDir.appendingPathComponent("Contents")
        try fm.createDirectory(at: appContents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)

        let appPlist: [String: Any] = [
            "CFBundleIdentifier": "com.ConjureDSP-user.ExportTemplate",
            "CFBundleName": "ConjureDSPExportAUTemplate",
            "CFBundleExecutable": "ConjureDSPExportAUTemplate",
            "CFBundlePackageType": "APPL",
        ]
        let appPlistData = try PropertyListSerialization.data(fromPropertyList: appPlist, format: .xml, options: 0)
        try appPlistData.write(to: appContents.appendingPathComponent("Info.plist"))

        // Dummy executable
        try Data("binary".utf8).write(to: appContents.appendingPathComponent("MacOS/ConjureDSPExportAUTemplate"))

        // .appex/Contents/Info.plist (extension)
        let appexContents = appContents
            .appendingPathComponent("PlugIns/ConjureDSPExportAUTemplateExtension.appex/Contents")
        try fm.createDirectory(at: appexContents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: appexContents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        let extPlist: [String: Any] = [
            "CFBundleIdentifier": "com.ConjureDSP-user.ExportTemplate.Extension",
            "CFBundleDisplayName": "ConjureDSPExportAUTemplateExtension",
            "CFBundleExecutable": "ConjureDSPExportAUTemplateExtension",
            "CFBundlePackageType": "XPC!",
            "NSExtension": [
                "NSExtensionAttributes": [
                    "AudioComponents": [[
                        "name": "ConjureDSP: ExportTemplate",
                        "type": "aufx",
                        "subtype": "TMPL",
                        "manufacturer": "CONJ",
                        "description": "ConjureDSP Export",
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
        try Data("binary".utf8).write(to: appexContents.appendingPathComponent("MacOS/ConjureDSPExportAUTemplateExtension"))

        // Placeholder preset.wasm
        try Data("placeholder".utf8).write(to: appexContents.appendingPathComponent("Resources/preset.wasm"))

        // Placeholder runtime-config.json
        let configJSON = try JSONSerialization.data(withJSONObject: [
            "version": 1, "language": "rust", "presetName": "ExportTemplate", "paramCount": 8,
        ] as [String: Any], options: .prettyPrinted)
        try configJSON.write(to: appexContents.appendingPathComponent("Resources/runtime-config.json"))

        // Zip the .app so ExportManager's unzipTemplate can unpack it
        let zipURL = tempDir.appendingPathComponent("ExportTemplate.zip")
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipProcess.arguments = ["-ck", "--keepParent", appDir.path, zipURL.path]
        try zipProcess.run()
        zipProcess.waitUntilExit()
        guard zipProcess.terminationStatus == 0 else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to zip mock template"])
        }

        // Remove raw .app — tests should only use the .zip
        try fm.removeItem(at: appDir)

        return zipURL
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
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex/Contents/Resources/preset.wasm")
        let writtenWasm = try Data(contentsOf: presetWasm)
        #expect(writtenWasm == wasmData)

        // Verify runtime-config.json
        let configURL = result
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex/Contents/Resources/runtime-config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
        #expect(config["language"] as? String == "rust")
        #expect(config["presetName"] as? String == "Bitcrusher")
        #expect(config["paramCount"] as? Int == 16)

        // Verify app plist patched
        let appPlistData = try Data(contentsOf: result.appendingPathComponent("Contents/Info.plist"))
        let appPlist = try PropertyListSerialization.propertyList(from: appPlistData, format: nil) as! [String: Any]
        #expect(appPlist["CFBundleIdentifier"] as? String == "com.ConjureDSP-user.Bitcrusher")
        #expect(appPlist["CFBundleName"] as? String == "Bitcrusher")

        // Verify extension plist patched
        let extPlistData = try Data(contentsOf: result
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex/Contents/Info.plist"))
        let extPlist = try PropertyListSerialization.propertyList(from: extPlistData, format: nil) as! [String: Any]
        #expect(extPlist["CFBundleIdentifier"] as? String == "com.ConjureDSP-user.Bitcrusher.Extension")

        let nsExt = extPlist["NSExtension"] as! [String: Any]
        let attrs = nsExt["NSExtensionAttributes"] as! [String: Any]
        let components = attrs["AudioComponents"] as! [[String: Any]]
        #expect(components[0]["name"] as? String == "ConjureDSP: Bitcrusher")
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
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex/Contents/Resources")

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

    @Test("ExportError.namModelNotFound has descriptive message")
    func exportErrorNamModelNotFoundMessage() {
        let error = ExportManager.ExportError.namModelNotFound("tone3000://99999/99999")
        #expect(error.errorDescription?.contains("tone3000://99999/99999") == true)
        #expect(error.errorDescription?.contains("not found") == true)
    }

    @Test("NAM load_model regex detects tone3000 paths in Python source")
    func namLoadModelRegexDetection() {
        let source = "from conjuredsp.nam import load_model\nmodel = load_model(\"tone3000://34/82524\")\ndef process():\n    pass\n"
        let regex = #"load_model\("([^"]+)"\)"#

        let range = source.range(of: regex, options: .regularExpression)
        #expect(range != nil, "Should detect load_model call")

        if let range = range {
            let match = source[range]
            // Extract path argument
            if let argRange = match.range(of: #""([^"]+)""#, options: .regularExpression) {
                let path = String(match[argRange].dropFirst().dropLast())
                #expect(path == "tone3000://34/82524")
            }
        }
    }

    @Test("Scoped load_model replacement preserves comments")
    func scopedLoadModelReplacement() {
        let path = "/tmp/test/model.nam"
        let source = "# Path: \(path)\nmodel = load_model(\"\(path)\")\n"
        let regex = #"load_model\("([^"]+)"\)"#

        if let callRange = source.range(of: regex, options: .regularExpression) {
            var rewritten = source
            rewritten.replaceSubrange(callRange, with: "load_model(\"model.nam\")")

            // The load_model call should be rewritten
            #expect(rewritten.contains("load_model(\"model.nam\")"))
            // The comment should be preserved
            #expect(rewritten.contains("# Path: \(path)"))
        } else {
            Issue.record("Regex should match")
        }
    }

    @Test func exportWithSkipSigning() throws {
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

        // Export with skipSigning: true — should succeed without calling codesign
        let result = try manager.exportPreset(
            name: "SkipSignTest",
            source: "fn process() {}",
            wasmData: Data("wasm".utf8),
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        // Verify output exists and plist was patched
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(result.lastPathComponent == "SkipSignTest.app")

        let appPlistData = try Data(contentsOf: result.appendingPathComponent("Contents/Info.plist"))
        let appPlist = try PropertyListSerialization.propertyList(from: appPlistData, format: nil) as! [String: Any]
        #expect(appPlist["CFBundleIdentifier"] as? String == "com.ConjureDSP-user.SkipSignTest")

        // Verify registered
        #expect(registry.entries.count == 1)
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
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex/Contents/Resources/preset.wasm")
        let written = try Data(contentsOf: wasmPath)
        #expect(written == wasm2)

        // Registry has only one entry (replaced)
        #expect(registry.entries.count == 1)
    }
}

// MARK: - PendingExportHandler Tests

@MainActor
struct PendingExportHandlerTests {

    @Test func appGroupContainerURLReturnsDeterministicPath() {
        // Direct path construction always returns a valid URL (no TCC prompt)
        let url = ExportManager.appGroupContainerURL()
        #expect(url.lastPathComponent == "group.com.MichaelJancsy.ConjureDSP")
        #expect(url.pathComponents.contains("Group Containers"))
    }

    @Test func exportManagerSanitizesSpecialCharacters() {
        #expect(ExportManager.sanitizeName("Hello World!") == "Hello_World")
        #expect(ExportManager.sanitizeName("test/path") == "test_path")
        #expect(ExportManager.sanitizeName("a.b.c") == "a_b_c")
    }
}

// MARK: - End-to-End Export Integration Tests

struct ExportIntegrationTests {

    /// Finds the real ExportTemplate.zip from the built extension bundle.
    /// Returns nil if the template hasn't been built yet.
    private func findRealTemplate() -> URL? {
        // The test host app embeds the extension; look for the template in its resources.
        // Path: ConjureDSP.app/Contents/PlugIns/ConjureDSPExtension.appex/Contents/Resources/ExportTemplate.zip
        let extensionBundle = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("ConjureDSPExtension.appex")
        if let extBundle = extensionBundle,
           let bundle = Bundle(url: extBundle),
           let templateURL = bundle.url(forResource: "ExportTemplate", withExtension: "zip") {
            return templateURL
        }
        // Fallback: search DerivedData for any built template
        let derivedData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        if let enumerator = FileManager.default.enumerator(
            at: derivedData,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == "ExportTemplate.zip"
                    && url.path.contains("ConjureDSPExtension.appex") {
                    return url
                }
            }
        }
        return nil
    }

    /// Full end-to-end test: export a Rust preset with real template, code sign,
    /// register with LaunchServices, verify AU is discoverable, clean up.
    @Test func exportAndRegisterRustPreset() throws {
        guard let templateURL = findRealTemplate() else {
            // Template not built — skip test rather than fail
            print("Skipping exportAndRegisterRustPreset: ExportTemplate.zip not found (build ConjureDSPExportAUTemplate first)")
            return
        }

        let fm = FileManager.default
        let testId = UUID().uuidString.prefix(8)
        let presetName = "IntegrationTest_\(testId)"
        let sanitized = ExportManager.sanitizeName(presetName)

        // Use the real export path — PluginKit only discovers extensions from
        // standard locations, not /tmp/
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let outputDir = appSupport.appendingPathComponent("ConjureDSP/Exports")
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let registryURL = fm.temporaryDirectory
            .appendingPathComponent("ExportRegistry_\(testId)")
            .appendingPathComponent("export-registry.json")

        // Cleanup everything on exit
        defer {
            let exportedApp = outputDir.appendingPathComponent("\(sanitized).app")
            try? fm.removeItem(at: exportedApp)
            try? fm.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Export the preset with signing
        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let wasmData = Data("fake wasm for test".utf8)

        let appURL = try manager.exportPreset(
            name: presetName,
            source: "fn process() {}",
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: false
        )

        // 2. Verify the .app bundle exists with correct structure
        #expect(fm.fileExists(atPath: appURL.path), "Exported .app should exist")
        let appexPath = appURL
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex")
        #expect(fm.fileExists(atPath: appexPath.path), "Extension .appex should exist inside exported .app")

        // 3. Verify code signature is valid
        let verifyProc = Process()
        verifyProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verifyProc.arguments = ["--verify", "--deep", "--strict", appURL.path]
        let verifyPipe = Pipe()
        verifyProc.standardError = verifyPipe
        try verifyProc.run()
        verifyProc.waitUntilExit()
        let codesignStderr = String(data: verifyPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(verifyProc.terminationStatus == 0,
                "codesign --verify should succeed on exported .app: \(codesignStderr)")

        // 4. Register with LaunchServices
        let lsregister = Process()
        lsregister.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister")
        lsregister.arguments = ["-f", "-R", "-trusted", appURL.path]
        try lsregister.run()
        lsregister.waitUntilExit()
        #expect(lsregister.terminationStatus == 0, "lsregister should succeed")

        // 5. Verify the exported AU is discoverable via pluginkit.
        //    lsregister triggers PluginKit discovery. Give it a moment, then check.
        //    Note: avoid killing AudioComponentRegistrar — it crashes the test runner.
        Thread.sleep(forTimeInterval: 3.0)

        // Use pluginkit -mv to check if our AU extension is registered
        let expectedBundleId = "com.ConjureDSP-user.\(sanitized).Extension"
        var pluginkitFound = false

        // Retry a few times — PluginKit discovery can take a moment
        for attempt in 1...3 {
            let pluginkit = Process()
            pluginkit.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            pluginkit.arguments = ["-mv", "-p", "com.apple.AudioUnit-UI"]
            let pluginkitPipe = Pipe()
            pluginkit.standardOutput = pluginkitPipe
            pluginkit.standardError = FileHandle.nullDevice
            try pluginkit.run()
            pluginkit.waitUntilExit()

            let pluginkitOutput = String(
                data: pluginkitPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

            if pluginkitOutput.contains(expectedBundleId) {
                pluginkitFound = true
                break
            }
            if attempt < 3 {
                Thread.sleep(forTimeInterval: 2.0)
            }
        }

        #expect(pluginkitFound,
                "pluginkit should list the exported AU extension (\(expectedBundleId))")

        // 6. Verify the exported AU plist has correct AudioComponents metadata
        let extPlistURL = appexPath.appendingPathComponent("Contents/Info.plist")
        let extPlistData = try Data(contentsOf: extPlistURL)
        let extPlist = try PropertyListSerialization.propertyList(from: extPlistData, format: nil) as! [String: Any]
        let nsExt = extPlist["NSExtension"] as! [String: Any]
        let attrs = nsExt["NSExtensionAttributes"] as! [String: Any]
        let components = attrs["AudioComponents"] as! [[String: Any]]
        #expect(components[0]["name"] as? String == "ConjureDSP: \(presetName)")
        #expect(components[0]["type"] as? String == "aufx")
        #expect(components[0]["manufacturer"] as? String == "CONJ")

        // 7. Verify registry was updated
        #expect(registry.entries.count == 1)
        #expect(registry.entries[0].name == presetName)
    }
}

// MARK: - Export DSP Integration Tests

/// Integration tests that export presets and verify audio processing via the Rust FFI.
/// Uses the same kernel-based approach as PresetComparisonTests — no AU instantiation needed.
@Suite(.serialized)
struct ExportDSPIntegrationTests {

    // MARK: - Constants

    private static let sampleRate: Double = 44100
    private static let channels: Int = 2
    private static let chunkSize: Int = 512
    private static let durationSeconds: Double = 0.5

    // MARK: - Error Type

    private struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Path Helpers

    private static var extensionResourcesURL: URL {
        get throws {
            guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
                throw TestError("Bundle.main.builtInPlugInsURL is nil")
            }
            let resourcesURL = plugInsURL
                .appendingPathComponent("ConjureDSPExtension.appex")
                .appendingPathComponent("Contents/Resources")
            guard FileManager.default.fileExists(atPath: resourcesURL.path) else {
                throw TestError("Extension resources not found at \(resourcesURL.path)")
            }
            return resourcesURL
        }
    }

    private static var pythonHome: String {
        get throws {
            let path = try extensionResourcesURL.appendingPathComponent("python-dist").path
            guard FileManager.default.fileExists(atPath: path) else {
                throw TestError("python-dist not found at \(path)")
            }
            return path
        }
    }

    private static var rustcURL: URL {
        get throws {
            let url = try extensionResourcesURL.appendingPathComponent("rustc-dist/bin/rustc")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TestError("rustc not found at \(url.path)")
            }
            return url
        }
    }

    private static var rustcSysroot: URL {
        get throws {
            try extensionResourcesURL.appendingPathComponent("rustc-dist")
        }
    }

    /// Repo root derived from this source file's path.
    private static var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConjureDSPTests/
            .deletingLastPathComponent()   // repo root
    }

    // MARK: - Signal Generation

    private static func generateSineSignal() -> ([Float], [Float]) {
        let totalSamples = Int(sampleRate * durationSeconds)
        var signal = [Float](repeating: 0, count: totalSamples)
        let freq: Double = 440.0
        let twoPi = 2.0 * Double.pi

        for i in 0..<totalSamples {
            let t = Double(i) / sampleRate
            let sine = Float(sin(twoPi * freq * t))
            let window = Float(0.5 * (1.0 - cos(twoPi * Double(i) / Double(totalSamples))))
            signal[i] = sine * window
        }
        return (signal, signal)
    }

    // MARK: - FFI Render Helper

    private static func renderSignal(
        kernel: DSPKernelRef,
        inputL: [Float],
        inputR: [Float]
    ) -> ([Float], [Float]) {
        let totalSamples = inputL.count
        var outputL = [Float](repeating: 0, count: totalSamples)
        var outputR = [Float](repeating: 0, count: totalSamples)

        var offset = 0
        while offset < totalSamples {
            let remaining = totalSamples - offset
            let frameCount = min(remaining, chunkSize)

            inputL.withUnsafeBufferPointer { inLBuf in
                inputR.withUnsafeBufferPointer { inRBuf in
                    outputL.withUnsafeMutableBufferPointer { outLBuf in
                        outputR.withUnsafeMutableBufferPointer { outRBuf in
                            var inputPtrs: [UnsafePointer<Float>?] = [
                                inLBuf.baseAddress! + offset,
                                inRBuf.baseAddress! + offset
                            ]
                            var outputPtrs: [UnsafeMutablePointer<Float>?] = [
                                outLBuf.baseAddress! + offset,
                                outRBuf.baseAddress! + offset
                            ]
                            inputPtrs.withUnsafeBufferPointer { inPtrs in
                                outputPtrs.withUnsafeMutableBufferPointer { outPtrs in
                                    dsp_kernel_process(
                                        kernel,
                                        inPtrs.baseAddress!,
                                        outPtrs.baseAddress!,
                                        UInt32(channels),
                                        UInt32(frameCount)
                                    )
                                }
                            }
                        }
                    }
                }
            }

            offset += frameCount
        }

        return (outputL, outputR)
    }

    // MARK: - WASM Compilation

    private static func compileToWasm(source: String) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conjuredsp-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputFile = tempDir.appendingPathComponent("dsp.rs")
        let outputFile = tempDir.appendingPathComponent("dsp.wasm")
        try source.write(to: inputFile, atomically: true, encoding: .utf8)

        let rustc = try rustcURL
        let sysroot = try rustcSysroot

        let process = Process()
        process.executableURL = rustc
        var args = [
            "--sysroot", sysroot.path,
            "--target", "wasm32-wasip1",
            "--edition", "2021",
            "-C", "opt-level=2",
            "--crate-type", "cdylib",
            "-o", outputFile.path,
            inputFile.path,
        ]

        let rlibPath = sysroot.appendingPathComponent("lib/libconjuredsp.rlib").path
        if FileManager.default.fileExists(atPath: rlibPath) {
            args = ["--extern", "conjuredsp=\(rlibPath)"] + args
        }

        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = sysroot.appendingPathComponent("lib").path
        process.environment = env

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
            throw TestError("rustc failed: \(stderr)")
        }

        return try Data(contentsOf: outputFile)
    }

    // MARK: - Template & Export Helpers

    private func findRealTemplate() -> URL? {
        let extensionBundle = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("ConjureDSPExtension.appex")
        if let extBundle = extensionBundle,
           let bundle = Bundle(url: extBundle),
           let templateURL = bundle.url(forResource: "ExportTemplate", withExtension: "zip") {
            return templateURL
        }
        return nil
    }

    private func makeTempOutputDir(testId: String) throws -> (URL, URL) {
        let fm = FileManager.default
        let outputDir = fm.temporaryDirectory
            .appendingPathComponent("ExportDSPTest_\(testId)")
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let registryURL = fm.temporaryDirectory
            .appendingPathComponent("ExportDSPReg_\(testId)")
            .appendingPathComponent("export-registry.json")
        return (outputDir, registryURL)
    }

    private func appexResourcesPath(in appURL: URL) -> URL {
        appURL
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex")
            .appendingPathComponent("Contents/Resources")
    }

    // MARK: - Integration Tests

    @Test("Export Rust passthrough preset and verify audio processing")
    func exportRustPresetAndVerifyAudio() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Read and compile Rust passthrough preset
        let resourcesURL = try Self.extensionResourcesURL
        let source = try String(contentsOf: resourcesURL.appendingPathComponent("preset_passthrough_rust.rs"), encoding: .utf8)
        let wasmData = try Self.compileToWasm(source: source)

        // 2. Export
        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_Passthrough_\(testId)",
            source: source,
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        // 3. Read exported WASM back from bundle
        let exportedWasm = try Data(contentsOf: appexResourcesPath(in: appURL).appendingPathComponent("preset.wasm"))
        #expect(exportedWasm == wasmData, "Exported WASM should match input")

        // 4. Load into fresh kernel and process audio
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let loaded = exportedWasm.withUnsafeBytes { buf in
            dsp_kernel_load_wasm(kernel, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(buf.count))
        }
        #expect(loaded, "WASM should load successfully into kernel")

        // 5. Process sine wave and verify passthrough
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        var maxError: Float = 0
        for i in 0..<inputL.count {
            maxError = max(maxError, abs(outputL[i] - inputL[i]))
            maxError = max(maxError, abs(outputR[i] - inputR[i]))
        }
        #expect(maxError < 1e-6, "Passthrough output should match input (max error: \(maxError))")
    }

    @Test("Export Python passthrough preset and verify audio processing")
    func exportPythonPresetAndVerifyAudio() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Read Python passthrough preset
        let resourcesURL = try Self.extensionResourcesURL
        let source = try String(contentsOf: resourcesURL.appendingPathComponent("preset_passthrough.py"), encoding: .utf8)

        // 2. Export
        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_PyPassthrough_\(testId)",
            source: source,
            wasmData: nil,
            language: .python,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        // 3. Read exported Python file back from bundle
        let exportedPy = try String(contentsOf: appexResourcesPath(in: appURL).appendingPathComponent("preset.py"), encoding: .utf8)
        #expect(exportedPy == source, "Exported Python should match input")

        // 4. Write to temp file and load into kernel
        let tempScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("export_test_\(testId).py")
        try exportedPy.write(to: tempScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempScript) }

        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let home = try Self.pythonHome
        let loaded = dsp_kernel_load_script(kernel, home, tempScript.path)
        #expect(loaded, "Python script should load successfully into kernel")

        // 5. Process sine wave and verify passthrough
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        var maxError: Float = 0
        for i in 0..<inputL.count {
            maxError = max(maxError, abs(outputL[i] - inputL[i]))
            maxError = max(maxError, abs(outputR[i] - inputR[i]))
        }
        #expect(maxError < 1e-6, "Passthrough output should match input (max error: \(maxError))")
    }

    @Test("Export Rust gainpan preset and verify non-trivial DSP processing")
    func exportRustPresetWithDSPVerifyProcessing() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Read and compile Rust gainpan preset (has rich params)
        let resourcesURL = try Self.extensionResourcesURL
        let source = try String(contentsOf: resourcesURL.appendingPathComponent("preset_gainpan_rust.rs"), encoding: .utf8)
        let wasmData = try Self.compileToWasm(source: source)

        // 2. Export with param metadata
        let metadata: [ParamMetadata] = [
            ParamMetadata(name: "Gain", key: "gain", min: -24, max: 12, default: 0, unit: "dB", curve: nil),
            ParamMetadata(name: "Pan", key: "pan", min: 0, max: 1, default: 0.5, unit: "", curve: nil),
        ]

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_GainPan_\(testId)",
            source: source,
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true,
            paramMetadata: metadata
        )

        // 3. Load exported WASM into kernel
        let exportedWasm = try Data(contentsOf: appexResourcesPath(in: appURL).appendingPathComponent("preset.wasm"))

        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let loaded = exportedWasm.withUnsafeBytes { buf in
            dsp_kernel_load_wasm(kernel, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(buf.count))
        }
        #expect(loaded, "WASM should load successfully")

        // 4. Set gain to minimum (-24 dB) by setting normalized param 0 to 0.0
        dsp_kernel_set_parameter(kernel, 0, 0.0)
        // Pan centered
        dsp_kernel_set_parameter(kernel, 1, 0.5)

        // 5. Process sine wave
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        // 6. Verify output is attenuated (not passthrough)
        // At -24 dB, gain ≈ 0.063. Output amplitude should be ~6% of input.
        let inputPeak = inputL.map { abs($0) }.max() ?? 0
        let outputPeak = max(outputL.map { abs($0) }.max() ?? 0, outputR.map { abs($0) }.max() ?? 0)

        #expect(inputPeak > 0.1, "Input should have significant amplitude")
        #expect(outputPeak > 0, "Output should not be silent")
        #expect(outputPeak < inputPeak * 0.2, "Output should be significantly attenuated at -24dB (input peak: \(inputPeak), output peak: \(outputPeak))")
    }

    @Test("Export with paramMetadata and verify runtime-config.json round-trip")
    func exportWithParamMetadataVerifyRoundTrip() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        let metadata: [ParamMetadata] = [
            ParamMetadata(name: "Cutoff", key: "cutoff", min: 20, max: 20000, default: 1000, unit: "Hz", curve: "log"),
            ParamMetadata(name: "Resonance", key: "resonance", min: 0, max: 1, default: 0.5, unit: "", curve: nil),
            ParamMetadata(name: "Mix", key: "mix", min: 0, max: 100, default: 100, unit: "%", curve: nil),
        ]

        // Use fake WASM (only testing config, not audio)
        let wasmData = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_Metadata_\(testId)",
            source: "fn process() {}",
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true,
            paramMetadata: metadata
        )

        // Parse runtime-config.json
        let configURL = appexResourcesPath(in: appURL).appendingPathComponent("runtime-config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]

        // Verify required fields
        #expect(config["version"] as? Int == 1)
        #expect(config["language"] as? String == "rust")
        #expect((config["presetName"] as? String)?.contains("ExportTest_Metadata") == true)
        #expect(config["paramCount"] as? Int == 3)

        // Verify paramMetadata array
        let metaArray = try #require(config["paramMetadata"] as? [[String: Any]])
        #expect(metaArray.count == 3)

        #expect(metaArray[0]["name"] as? String == "Cutoff")
        #expect(metaArray[0]["key"] as? String == "cutoff")
        #expect(metaArray[0]["min"] as? Float == 20)
        #expect(metaArray[0]["max"] as? Float == 20000)
        #expect(metaArray[0]["default"] as? Float == 1000)
        #expect(metaArray[0]["unit"] as? String == "Hz")
        #expect(metaArray[0]["curve"] as? String == "log")

        #expect(metaArray[1]["name"] as? String == "Resonance")
        #expect(metaArray[1]["curve"] == nil, "Linear curve should be omitted")

        // Verify backward-compat paramNames
        let names = try #require(config["paramNames"] as? [String])
        #expect(names == ["Cutoff", "Resonance", "Mix"])
    }

    @Test("Export runtime-config.json contains all required fields for both languages")
    func exportRuntimeConfigRequiredFields() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)

        // Export Rust preset
        let wasmData = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
        let rustURL = try manager.exportPreset(
            name: "ConfigTest_Rust_\(testId)",
            source: "fn process() {}",
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        // Export Python preset
        let pyURL = try manager.exportPreset(
            name: "ConfigTest_Python_\(testId)",
            source: "def process(inputs, outputs, frame_count, sample_rate, params): pass",
            wasmData: nil,
            language: .python,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        let requiredKeys = ["version", "language", "presetName", "exportDate", "paramCount"]

        for (url, lang) in [(rustURL, "rust"), (pyURL, "python")] {
            let configData = try Data(contentsOf: appexResourcesPath(in: url).appendingPathComponent("runtime-config.json"))
            let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]

            for key in requiredKeys {
                #expect(config[key] != nil, "\(lang) config missing required field '\(key)'")
            }
            #expect(config["language"] as? String == lang)
        }
    }

    @Test("Export with very long preset name")
    func exportWithVeryLongPresetName() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        let longName = String(repeating: "A", count: 200) + "_\(testId)"
        let wasmData = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: longName,
            source: "fn process() {}",
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        // Export should succeed
        #expect(FileManager.default.fileExists(atPath: appURL.path))

        // Verify runtime-config preserves full name
        let configData = try Data(contentsOf: appexResourcesPath(in: appURL).appendingPathComponent("runtime-config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
        #expect(config["presetName"] as? String == longName)

        // Verify plist contains the full name in AU display
        let extPlistURL = appURL
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex")
            .appendingPathComponent("Contents/Info.plist")
        let plistData = try Data(contentsOf: extPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        let nsExt = plist["NSExtension"] as! [String: Any]
        let attrs = nsExt["NSExtensionAttributes"] as! [String: Any]
        let components = attrs["AudioComponents"] as! [[String: Any]]
        #expect(components[0]["name"] as? String == "ConjureDSP: \(longName)")
    }

    // MARK: - NAM Serialization Helper

    /// Serialize a .nam JSON file to the binary protocol used by `dsp_kernel_inject_nam()`.
    /// This replicates the serialization in `ExportAUAudioUnit.injectEmbeddedNamModel()` exactly.
    private static func serializeNamFile(at url: URL) throws -> Data {
        let namData = try Data(contentsOf: url)
        let namJson = try JSONSerialization.jsonObject(with: namData) as! [String: Any]

        let architecture = namJson["architecture"] as! String
        let configObj = namJson["config"]!
        let weightsArray = namJson["weights"] as! [Double]

        let arch: UInt32 = architecture == "LSTM" ? 1 : 0
        let sampleRate = Float(
            (namJson["sample_rate"] as? Double)
            ?? (namJson["sample_rate"] as? Int).map(Double.init)
            ?? 48000.0
        )

        let configData = try JSONSerialization.data(withJSONObject: configObj)

        var binary = Data()
        var archLE = arch.littleEndian
        binary.append(Data(bytes: &archLE, count: 4))
        var srLE = sampleRate.bitPattern.littleEndian
        binary.append(Data(bytes: &srLE, count: 4))
        var configLen = UInt32(configData.count).littleEndian
        binary.append(Data(bytes: &configLen, count: 4))
        binary.append(configData)
        var weightCount = UInt32(weightsArray.count).littleEndian
        binary.append(Data(bytes: &weightCount, count: 4))
        for w in weightsArray {
            var f = Float(w).bitPattern.littleEndian
            binary.append(Data(bytes: &f, count: 4))
        }

        return binary
    }

    /// Helper to get the last kernel error as a Swift string.
    private static func kernelError(_ kernel: DSPKernelRef) -> String {
        if let ptr = dsp_kernel_last_error(kernel) {
            return String(cString: ptr)
        }
        return "(none)"
    }

    // MARK: - NAM Integration Tests

    @Test("NAM LSTM preset processes audio correctly (not static)")
    func namLstmPresetProducesCorrectAudio() throws {
        // 1. Compile NAM preset source to WASM
        let resourcesURL = try Self.extensionResourcesURL
        let source = try String(contentsOf: resourcesURL.appendingPathComponent("preset_nam_rust.rs"), encoding: .utf8)
        let wasmData = try Self.compileToWasm(source: source)

        // 2. Create kernel and load WASM
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let loaded = wasmData.withUnsafeBytes { buf in
            dsp_kernel_load_wasm(kernel, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(buf.count))
        }
        #expect(loaded, "WASM should load successfully")

        // 3. Verify WASM declares a NAM path
        let namPathPtr = dsp_kernel_nam_path(kernel)
        #expect(namPathPtr != nil, "NAM preset should report a NAM path")

        // 4. Read and serialize .nam file (same as ExportAUAudioUnit does)
        let namURL = Self.repoRootURL.appendingPathComponent("tone3000_py_demo/lstm_tiny.nam")
        let binary = try Self.serializeNamFile(at: namURL)

        // 5. Inject NAM model
        let injected = binary.withUnsafeBytes { rawBuffer -> Bool in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return dsp_kernel_inject_nam(kernel, ptr, UInt(binary.count))
        }
        #expect(injected, "NAM injection should succeed. Error: \(Self.kernelError(kernel))")

        // 6a. Process SILENCE — output should be near-zero, not static
        let silenceL = [Float](repeating: 0, count: Int(Self.sampleRate * Self.durationSeconds))
        let silenceR = silenceL
        let (silOutL, silOutR) = Self.renderSignal(kernel: kernel, inputL: silenceL, inputR: silenceR)

        let silencePeakL = silOutL.map { abs($0) }.max() ?? 0
        let silencePeakR = silOutR.map { abs($0) }.max() ?? 0
        #expect(silencePeakL < 0.1, "Silence input should not produce loud output (peak L: \(silencePeakL))")
        #expect(silencePeakR < 0.1, "Silence input should not produce loud output (peak R: \(silencePeakR))")

        // 6b. Process SINE WAVE
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        // Verify output is finite (no NaN/Inf)
        for i in 0..<outputL.count {
            #expect(outputL[i].isFinite, "Output L[\(i)] is not finite: \(outputL[i])")
            #expect(outputR[i].isFinite, "Output R[\(i)] is not finite: \(outputR[i])")
        }

        // Verify output is not all zeros (model is processing)
        let outputPeakL = outputL.map { abs($0) }.max() ?? 0
        #expect(outputPeakL > 1e-6, "Output should not be silent (peak L: \(outputPeakL))")

        // Verify output differs from input (model modifies signal)
        var maxDiff: Float = 0
        for i in 0..<inputL.count {
            maxDiff = max(maxDiff, abs(outputL[i] - inputL[i]))
        }
        #expect(maxDiff > 1e-4, "Output should differ from input (maxDiff: \(maxDiff))")
    }

    @Test("NAM WaveNet preset processes audio correctly (not static)")
    func namWavenetPresetProducesCorrectAudio() throws {
        // 1. Compile NAM preset source to WASM
        let resourcesURL = try Self.extensionResourcesURL
        let source = try String(contentsOf: resourcesURL.appendingPathComponent("preset_nam_rust.rs"), encoding: .utf8)
        let wasmData = try Self.compileToWasm(source: source)

        // 2. Create kernel and load WASM
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let loaded = wasmData.withUnsafeBytes { buf in
            dsp_kernel_load_wasm(kernel, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(buf.count))
        }
        #expect(loaded, "WASM should load successfully")

        // 3. Verify WASM declares a NAM path
        let namPathPtr = dsp_kernel_nam_path(kernel)
        #expect(namPathPtr != nil, "NAM preset should report a NAM path")

        // 4. Read and serialize .nam file (same as ExportAUAudioUnit does)
        let namURL = Self.repoRootURL.appendingPathComponent("tone3000_py_demo/wavenet_tiny.nam")
        let binary = try Self.serializeNamFile(at: namURL)

        // 5. Inject NAM model
        let injected = binary.withUnsafeBytes { rawBuffer -> Bool in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return dsp_kernel_inject_nam(kernel, ptr, UInt(binary.count))
        }
        #expect(injected, "NAM injection should succeed. Error: \(Self.kernelError(kernel))")

        // 6a. Process SILENCE — output should be near-zero, not static
        let silenceL = [Float](repeating: 0, count: Int(Self.sampleRate * Self.durationSeconds))
        let silenceR = silenceL
        let (silOutL, silOutR) = Self.renderSignal(kernel: kernel, inputL: silenceL, inputR: silenceR)

        let silencePeakL = silOutL.map { abs($0) }.max() ?? 0
        let silencePeakR = silOutR.map { abs($0) }.max() ?? 0
        #expect(silencePeakL < 0.1, "Silence input should not produce loud output (peak L: \(silencePeakL))")
        #expect(silencePeakR < 0.1, "Silence input should not produce loud output (peak R: \(silencePeakR))")

        // 6b. Process SINE WAVE
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        // Verify output is finite (no NaN/Inf)
        for i in 0..<outputL.count {
            #expect(outputL[i].isFinite, "Output L[\(i)] is not finite: \(outputL[i])")
            #expect(outputR[i].isFinite, "Output R[\(i)] is not finite: \(outputR[i])")
        }

        // Verify output is not all zeros (model is processing)
        let outputPeakL = outputL.map { abs($0) }.max() ?? 0
        #expect(outputPeakL > 1e-6, "Output should not be silent (peak L: \(outputPeakL))")

        // Verify output differs from input (model modifies signal)
        var maxDiff: Float = 0
        for i in 0..<inputL.count {
            maxDiff = max(maxDiff, abs(outputL[i] - inputL[i]))
        }
        #expect(maxDiff > 1e-4, "Output should differ from input (maxDiff: \(maxDiff))")
    }

    // MARK: - NAM Export Pipeline Tests

    @Test("Export Python NAM preset: bundle has model.nam, preset.py is rewritten, runtime-config has namModelFile")
    func exportPythonNamPresetBundleIsCorrect() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Read Python NAM preset and replace the default tone3000 URL with a real absolute path
        let namURL = Self.repoRootURL.appendingPathComponent("tone3000_py_demo/lstm_tiny.nam")
        let resourcesURL = try Self.extensionResourcesURL
        var source = try String(contentsOf: resourcesURL.appendingPathComponent("preset_nam.py"), encoding: .utf8)
        source = source.replacingOccurrences(of: "tone3000://60092/351559", with: namURL.path)
        #expect(source.contains(namURL.path), "Source should contain absolute NAM path after substitution")

        // 2. Export
        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_PythonNAM_\(testId)",
            source: source,
            wasmData: nil,
            language: .python,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        let resources = appexResourcesPath(in: appURL)

        // 3. model.nam must be present in the bundle
        let exportedNamURL = resources.appendingPathComponent("model.nam")
        #expect(FileManager.default.fileExists(atPath: exportedNamURL.path),
                "model.nam should be present in exported bundle")

        // 4. preset.py must have the load_model call rewritten to "model.nam"
        let exportedPy = try String(contentsOf: resources.appendingPathComponent("preset.py"), encoding: .utf8)
        #expect(exportedPy.contains(#"load_model("model.nam")"#),
                "Exported preset.py should reference model.nam, not the original path")
        // The load_model() call itself must not have the original path (comments may still contain it)
        #expect(!exportedPy.contains("load_model(\"\(namURL.path)\")"),
                "load_model() call in exported preset.py should not contain the original absolute path")

        // 5. runtime-config.json must record namModelFile
        let configData = try Data(contentsOf: resources.appendingPathComponent("runtime-config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
        #expect(config["namModelFile"] as? String == "model.nam",
                "runtime-config.json should have namModelFile = \"model.nam\"")

        // 6. Exported model.nam must be byte-for-byte identical to the source file
        let exportedNamData = try Data(contentsOf: exportedNamURL)
        let originalNamData = try Data(contentsOf: namURL)
        #expect(exportedNamData == originalNamData,
                "Exported model.nam should match original lstm_tiny.nam")
    }

    @Test("Export Rust NAM preset: bundle has model.nam, runtime-config correct, audio processes correctly")
    func exportRustNamPresetBundleAndVerifyAudio() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // 1. Read Rust NAM preset and replace the default tone3000 URL with a real absolute path
        let namURL = Self.repoRootURL.appendingPathComponent("tone3000_py_demo/lstm_tiny.nam")
        let resourcesURL = try Self.extensionResourcesURL
        var source = try String(contentsOf: resourcesURL.appendingPathComponent("preset_nam_rust.rs"), encoding: .utf8)
        source = source.replacingOccurrences(of: "tone3000://60092/351559", with: namURL.path)
        #expect(source.contains(namURL.path), "Source should contain absolute NAM path after substitution")

        // 2. Compile to WASM
        let wasmData = try Self.compileToWasm(source: source)

        // 3. Export
        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)
        let appURL = try manager.exportPreset(
            name: "ExportTest_RustNAM_\(testId)",
            source: source,
            wasmData: wasmData,
            language: .rust,
            templateURL: templateURL,
            outputDirectory: outputDir,
            skipSigning: true
        )

        let resources = appexResourcesPath(in: appURL)

        // 4. model.nam must be present in the bundle
        let exportedNamURL = resources.appendingPathComponent("model.nam")
        #expect(FileManager.default.fileExists(atPath: exportedNamURL.path),
                "model.nam should be present in exported bundle")

        // 5. runtime-config.json must record namModelFile
        let configData = try Data(contentsOf: resources.appendingPathComponent("runtime-config.json"))
        let config = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
        #expect(config["namModelFile"] as? String == "model.nam",
                "runtime-config.json should have namModelFile = \"model.nam\"")

        // 6. Exported model.nam must be byte-for-byte identical to the source file
        let exportedNamData = try Data(contentsOf: exportedNamURL)
        let originalNamData = try Data(contentsOf: namURL)
        #expect(exportedNamData == originalNamData,
                "Exported model.nam should match original lstm_tiny.nam")

        // 7. Audio round-trip: load exported WASM + inject exported model.nam, verify output
        let exportedWasm = try Data(contentsOf: resources.appendingPathComponent("preset.wasm"))

        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        dsp_kernel_set_max_frames(kernel, UInt32(Self.chunkSize))

        let loaded = exportedWasm.withUnsafeBytes { buf in
            dsp_kernel_load_wasm(kernel, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt32(buf.count))
        }
        #expect(loaded, "Exported WASM should load successfully into kernel")

        // Serialize and inject the exported model.nam (same binary protocol as ExportAUAudioUnit)
        let binary = try Self.serializeNamFile(at: exportedNamURL)
        let injected = binary.withUnsafeBytes { rawBuffer -> Bool in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return dsp_kernel_inject_nam(kernel, ptr, UInt(binary.count))
        }
        #expect(injected, "NAM injection from exported model.nam should succeed. Error: \(Self.kernelError(kernel))")

        // Process silence — must not produce loud output (not static)
        let silenceL = [Float](repeating: 0, count: Int(Self.sampleRate * Self.durationSeconds))
        let silenceR = silenceL
        let (silOutL, silOutR) = Self.renderSignal(kernel: kernel, inputL: silenceL, inputR: silenceR)
        let silencePeakL = silOutL.map { abs($0) }.max() ?? 0
        let silencePeakR = silOutR.map { abs($0) }.max() ?? 0
        #expect(silencePeakL < 0.1, "Silence input should not produce loud output (peak L: \(silencePeakL))")
        #expect(silencePeakR < 0.1, "Silence input should not produce loud output (peak R: \(silencePeakR))")

        // Process sine wave — must be finite, non-silent, and differ from input
        let (inputL, inputR) = Self.generateSineSignal()
        let (outputL, outputR) = Self.renderSignal(kernel: kernel, inputL: inputL, inputR: inputR)

        for i in 0..<outputL.count {
            #expect(outputL[i].isFinite, "Output L[\(i)] is not finite: \(outputL[i])")
            #expect(outputR[i].isFinite, "Output R[\(i)] is not finite: \(outputR[i])")
        }

        let outputPeakL = outputL.map { abs($0) }.max() ?? 0
        #expect(outputPeakL > 1e-6, "Output should not be silent (peak L: \(outputPeakL))")

        var maxDiff: Float = 0
        for i in 0..<inputL.count {
            maxDiff = max(maxDiff, abs(outputL[i] - inputL[i]))
        }
        #expect(maxDiff > 1e-4, "Output should differ from input (maxDiff: \(maxDiff))")
    }

    @Test("Export NAM preset throws namModelNotFound when model file does not exist")
    func exportNamPresetThrowsWhenModelMissing() throws {
        guard let templateURL = findRealTemplate() else {
            print("Skipping: ExportTemplate.zip not found")
            return
        }

        let testId = UUID().uuidString.prefix(8)
        let (outputDir, registryURL) = try makeTempOutputDir(testId: String(testId))
        defer {
            try? FileManager.default.removeItem(at: outputDir)
            try? FileManager.default.removeItem(at: registryURL.deletingLastPathComponent())
        }

        // Minimal Python NAM source referencing a nonexistent absolute path
        let source = """
            from conjuredsp.nam import load_model
            model = load_model("/nonexistent/bogus/model.nam")
            def process(inputs, outputs, frame_count, sample_rate, params):
                pass
            """

        let registry = ExportRegistry(registryURL: registryURL)
        let manager = ExportManager(registry: registry)

        #expect(throws: ExportManager.ExportError.self) {
            try manager.exportPreset(
                name: "ExportTest_MissingNAM_\(testId)",
                source: source,
                wasmData: nil,
                language: .python,
                templateURL: templateURL,
                outputDirectory: outputDir,
                skipSigning: true
            )
        }
    }
}

// MARK: - Edge Case Tests

struct ExportEdgeCaseTests {

    @Test func exportPresetNameWithUnicode() {
        let sanitized = ExportManager.sanitizeName("超级混响 🎵 Effect!")
        // Unicode chars and emoji become underscores
        #expect(!sanitized.isEmpty)
        #expect(!sanitized.contains("🎵"))
        // Should only contain alphanumeric, hyphens, underscores
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for scalar in sanitized.unicodeScalars {
            #expect(allowed.contains(scalar), "Unexpected char: \(scalar)")
        }
    }

    @Test func exportPresetNameAllSpecialChars() {
        let sanitized = ExportManager.sanitizeName("!!@@##$$")
        #expect(sanitized == "Untitled", "All-special-char name should fall back to Untitled")
    }

    @Test func exportPresetNameEmpty() {
        let sanitized = ExportManager.sanitizeName("")
        #expect(sanitized == "Untitled", "Empty name should fall back to Untitled")
    }

    @Test func exportPresetNameOnlyUnderscores() {
        let sanitized = ExportManager.sanitizeName("___")
        // After trimming underscores, this becomes empty → Untitled
        #expect(sanitized == "Untitled")
    }

    @Test func exportPresetNameWithSpaces() {
        let sanitized = ExportManager.sanitizeName("My Cool Reverb")
        #expect(sanitized == "My_Cool_Reverb")
    }
}

// MARK: - NAM Reference Detection Tests

struct ExportNamReferenceTests {

    @Test func pythonTone3000Reference() {
        let source = """
        from conjuredsp.nam import load_model
        model = load_model("tone3000://60092/351559")
        def process(inputs, outputs, frame_count, sample_rate, params):
            pass
        """
        #expect(ExportManager.containsNamReference(source: source, language: .python))
    }

    @Test func pythonLocalFileReference() {
        let source = #"model = load_model("/Users/foo/models/my_amp.nam")"#
        #expect(ExportManager.containsNamReference(source: source, language: .python))
    }

    @Test func pythonTildeFileReference() {
        let source = #"m = load_model("~/Music/tones/lead.nam")"#
        #expect(ExportManager.containsNamReference(source: source, language: .python))
    }

    @Test func rustTone3000Reference() {
        let source = """
        use conjuredsp::*;
        conjuredsp::nam!("tone3000://60092/351559");
        """
        #expect(ExportManager.containsNamReference(source: source, language: .rust))
    }

    @Test func rustLocalFileReference() {
        let source = #"nam!("/Users/foo/bar.nam");"#
        #expect(ExportManager.containsNamReference(source: source, language: .rust))
    }

    @Test func pythonWithoutNamReference() {
        let source = """
        def process(inputs, outputs, frame_count, sample_rate, params):
            outputs[:] = inputs * params["gain"]
        """
        #expect(!ExportManager.containsNamReference(source: source, language: .python))
    }

    @Test func rustWithoutNamReference() {
        let source = """
        use conjuredsp::*;
        setup!();
        params! { GAIN = db() }
        fn process() {}
        """
        #expect(!ExportManager.containsNamReference(source: source, language: .rust))
    }

    @Test func pythonMacroPatternIgnoredForPython() {
        // Rust nam!(...) macro should not match the Python detector.
        let source = #"# nam!("tone3000://1/2")"#
        #expect(!ExportManager.containsNamReference(source: source, language: .python))
    }

    @Test func rustLoadModelIgnoredForRust() {
        // Python load_model() call should not match the Rust detector.
        let source = #"// load_model("foo.nam")"#
        #expect(!ExportManager.containsNamReference(source: source, language: .rust))
    }
}

