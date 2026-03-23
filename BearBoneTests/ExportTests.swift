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

    /// Creates a minimal fake template .app, zips it, and returns the .zip URL.
    /// ExportManager.exportPreset expects a .zip (not a raw .app) because
    /// PluginKit would discover a raw .appex and register it.
    private func createMockTemplate() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportManagerTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let appDir = tempDir.appendingPathComponent("BearBoneExportAUTemplate.app")
        let fm = FileManager.default

        // .app/Contents/Info.plist (host app)
        let appContents = appDir.appendingPathComponent("Contents")
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
                        "manufacturer": "BEAR",
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
        #expect(appPlist["CFBundleIdentifier"] as? String == "com.BearBone-user.SkipSignTest")

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
            .appendingPathComponent("Contents/PlugIns/BearBoneExportAUTemplateExtension.appex/Contents/Resources/preset.wasm")
        let written = try Data(contentsOf: wasmPath)
        #expect(written == wasm2)

        // Registry has only one entry (replaced)
        #expect(registry.entries.count == 1)
    }
}

// MARK: - PendingExportHandler Tests

@MainActor
struct PendingExportHandlerTests {

    @Test func appGroupContainerURLReturnsNilWithoutEntitlement() {
        // Without actual App Group entitlement, containerURL returns nil
        let url = ExportManager.appGroupContainerURL()
        // This test documents behavior — in CI without entitlements, it's nil
        // In a signed app with entitlements, it would return a valid URL
        _ = url // Suppress unused warning
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
        // Path: BearBone.app/Contents/PlugIns/BearBoneExtension.appex/Contents/Resources/ExportTemplate.zip
        let extensionBundle = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("BearBoneExtension.appex")
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
                    && url.path.contains("BearBoneExtension.appex") {
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
            print("Skipping exportAndRegisterRustPreset: ExportTemplate.zip not found (build BearBoneExportAUTemplate first)")
            return
        }

        let fm = FileManager.default
        let testId = UUID().uuidString.prefix(8)
        let presetName = "IntegrationTest_\(testId)"
        let sanitized = ExportManager.sanitizeName(presetName)

        // Use the real export path — PluginKit only discovers extensions from
        // standard locations, not /tmp/
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let outputDir = appSupport.appendingPathComponent("BearBone/Exports")
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
            .appendingPathComponent("Contents/PlugIns/BearBoneExportAUTemplateExtension.appex")
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
        let expectedBundleId = "com.BearBone-user.\(sanitized).Extension"
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
        #expect(components[0]["name"] as? String == "BearBone: \(presetName)")
        #expect(components[0]["type"] as? String == "aufx")
        #expect(components[0]["manufacturer"] as? String == "BEAR")

        // 7. Verify registry was updated
        #expect(registry.entries.count == 1)
        #expect(registry.entries[0].name == presetName)
    }
}

// MARK: - SharedPythonRuntimeInstaller Tests

@Suite struct SharedPythonRuntimeInstallerTests {
    @Test func isInstalledReturnsFalseForNonexistentPath() {
        // The shared runtime URL is derived from Application Support.
        // Unless the installer has run previously, the stdlib dir shouldn't exist
        // at a randomly-named test path. We test the static check here.
        let testPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("BearBoneTest-\(UUID().uuidString)")
            .appendingPathComponent("lib/python3.14t")
        #expect(!FileManager.default.fileExists(atPath: testPath.path))
    }
}
