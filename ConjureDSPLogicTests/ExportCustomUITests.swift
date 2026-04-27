import Foundation
import Testing

/// Tests for Phase E — ExportManager carrying a preset bundle's custom UI
/// into the exported AU. Uses a synthetic "template" (a zipped directory
/// shaped like the real ExportTemplate.app) so we can assert the
/// copy-into-appex + runtime-config behavior without depending on the real
/// template, which requires a full Release build of the template project.
///
/// Lives in the logic tests target so it runs fast (no app launch) and
/// doesn't require `TEST_HOST`. Relies on the local copy of ExportManager
/// in ConjureDSPLogicTests/ExportManager.swift.
struct ExportCustomUITests {

    // MARK: - Helpers

    /// Build a minimal template .app directory tree and zip it, mirroring
    /// the real ExportTemplate layout just enough to satisfy
    /// ExportManager.exportPreset. The tree has:
    ///   .app/Contents/Info.plist
    ///   .app/Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex/Contents/Info.plist
    ///   .app/Contents/PlugIns/.../Contents/Resources/{preset.wasm,runtime-config.json}
    /// Returns the path to the zip.
    private static func makeFakeTemplateZip() throws -> URL {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("ExportCustomUITests_\(UUID().uuidString)", isDirectory: true)
        let app = tempRoot.appendingPathComponent("ConjureDSPExportAUTemplate.app", isDirectory: true)
        let appContents = app.appendingPathComponent("Contents", isDirectory: true)
        let appex = appContents
            .appendingPathComponent("PlugIns/ConjureDSPExportAUTemplateExtension.appex", isDirectory: true)
        let appexContents = appex.appendingPathComponent("Contents", isDirectory: true)
        let appexResources = appexContents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: appexResources, withIntermediateDirectories: true)

        // App Info.plist — patched by exporter
        let appInfo: [String: Any] = [
            "CFBundleIdentifier": "com.ConjureDSP-user.ExportTemplate",
            "CFBundleName": "ConjureDSPExportAUTemplate",
            "CFBundleDisplayName": "ConjureDSPExportAUTemplate",
            "CFBundleExecutable": "ConjureDSPExportAUTemplate",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        try (try PropertyListSerialization.data(fromPropertyList: appInfo, format: .xml, options: 0))
            .write(to: appContents.appendingPathComponent("Info.plist"))

        // Extension Info.plist — patched by exporter (needs AudioComponents block)
        let extInfo: [String: Any] = [
            "CFBundleIdentifier": "com.ConjureDSP-user.ExportTemplate.Extension",
            "CFBundleDisplayName": "ConjureDSPExportAUTemplateExtension",
            "CFBundleExecutable": "ConjureDSPExportAUTemplateExtension",
            "NSExtension": [
                "NSExtensionPointIdentifier": "com.apple.AudioUnit-UI",
                "NSExtensionAttributes": [
                    "AudioComponents": [[
                        "description": "ConjureDSP Export",
                        "manufacturer": "CONJ",
                        "name": "ConjureDSP: ExportTemplate",
                        "sandboxSafe": true,
                        "subtype": "TMPL",
                        "type": "aufx",
                        "version": 1,
                    ] as [String: Any]],
                ] as [String: Any],
            ] as [String: Any],
        ]
        try (try PropertyListSerialization.data(fromPropertyList: extInfo, format: .xml, options: 0))
            .write(to: appexContents.appendingPathComponent("Info.plist"))

        // Placeholder preset payload — the exporter will overwrite these.
        try Data("placeholder".utf8).write(to: appexResources.appendingPathComponent("preset.wasm"))
        try Data("{}".utf8).write(to: appexResources.appendingPathComponent("runtime-config.json"))

        // Zip it the way build-template.sh does: `ditto -ck --sequesterRsrc --keepParent`.
        let zipURL = tempRoot.appendingPathComponent("ExportTemplate.zip")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-ck", "--sequesterRsrc", "--keepParent", app.path, zipURL.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "ExportCustomUITests", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "ditto failed"])
        }
        return zipURL
    }

    /// Set up a fake preset bundle's `ui/` directory with index.html + an
    /// asset, then return the ui dir URL.
    private static func makeFakeUIDirectory() throws -> URL {
        let fm = FileManager.default
        let uiDir = fm.temporaryDirectory
            .appendingPathComponent("FakePresetUI_\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("ui", isDirectory: true)
        try fm.createDirectory(at: uiDir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "<!doctype html><title>custom</title>".write(
            to: uiDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "body{color:red}".write(
            to: uiDir.appendingPathComponent("assets/style.css"), atomically: true, encoding: .utf8)
        return uiDir
    }

    private static func runExport(
        customUI: ExportManager.CustomUIPayload?,
        outputDir: URL,
        registryURL: URL,
        name: String
    ) throws -> URL {
        let templateZip = try makeFakeTemplateZip()
        defer { try? FileManager.default.removeItem(at: templateZip.deletingLastPathComponent()) }
        let manager = ExportManager(registry: ExportRegistry(registryURL: registryURL))
        return try manager.exportPreset(
            name: name,
            source: "def process(): pass\n",
            wasmData: nil,
            language: .python,
            templateURL: templateZip,
            outputDirectory: outputDir,
            skipSigning: true,
            customUI: customUI
        )
    }

    private static func appexResources(_ appURL: URL) -> URL {
        appURL
            .appendingPathComponent("Contents/PlugIns/ConjureDSPExportAUTemplateExtension.appex")
            .appendingPathComponent("Contents/Resources")
    }

    private static func cleanup(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private static func tempOutputDir() -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportCustomUITests_\(UUID().uuidString)", isDirectory: true)
        let out = base.appendingPathComponent("out", isDirectory: true)
        let reg = base.appendingPathComponent("registry.json")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return (out, reg)
    }

    // MARK: - Export carries ui/ into appex

    @Test func exportCopiesUIDirectoryIntoAppex() throws {
        let uiDir = try Self.makeFakeUIDirectory()
        let (outDir, regURL) = Self.tempOutputDir()
        defer { Self.cleanup(outDir.deletingLastPathComponent(), uiDir.deletingLastPathComponent()) }

        let payload = ExportManager.CustomUIPayload(
            directory: uiDir, entryHTML: "index.html",
            width: 420, height: 320, fps: 30, audioFrames: true
        )
        let appURL = try Self.runExport(
            customUI: payload, outputDir: outDir, registryURL: regURL, name: "CustomUIExport1"
        )

        // ui/ present in the exported appex with both files.
        let exportedUIDir = Self.appexResources(appURL).appendingPathComponent("ui")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: exportedUIDir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath:
            exportedUIDir.appendingPathComponent("index.html").path))
        #expect(FileManager.default.fileExists(atPath:
            exportedUIDir.appendingPathComponent("assets/style.css").path))
    }

    @Test func runtimeConfigHasCustomUIFields() throws {
        let uiDir = try Self.makeFakeUIDirectory()
        let (outDir, regURL) = Self.tempOutputDir()
        defer { Self.cleanup(outDir.deletingLastPathComponent(), uiDir.deletingLastPathComponent()) }

        let payload = ExportManager.CustomUIPayload(
            directory: uiDir, entryHTML: "index.html",
            width: 500, height: 360, fps: 30, audioFrames: true
        )
        let appURL = try Self.runExport(
            customUI: payload, outputDir: outDir, registryURL: regURL, name: "CustomUIExport2"
        )

        let configURL = Self.appexResources(appURL).appendingPathComponent("runtime-config.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL))
        guard let dict = raw as? [String: Any] else {
            Issue.record("runtime-config.json is not a dictionary"); return
        }

        #expect(dict["hasCustomUI"] as? Bool == true)
        guard let ui = dict["ui"] as? [String: Any] else {
            Issue.record("runtime-config.ui missing"); return
        }
        #expect(ui["entryHTML"] as? String == "index.html")
        #expect(ui["width"] as? Int == 500)
        #expect(ui["height"] as? Int == 360)
        #expect(ui["fps"] as? Int == 30)
        #expect(ui["audioFrames"] as? Bool == true)
    }

    @Test func exportWithoutCustomUIHasNoUIFields() throws {
        let (outDir, regURL) = Self.tempOutputDir()
        defer { Self.cleanup(outDir.deletingLastPathComponent()) }

        let appURL = try Self.runExport(
            customUI: nil, outputDir: outDir, registryURL: regURL, name: "NoCustomUIExport"
        )

        // No ui/ subdirectory.
        let exportedUIDir = Self.appexResources(appURL).appendingPathComponent("ui")
        #expect(!FileManager.default.fileExists(atPath: exportedUIDir.path))

        // runtime-config.json should omit hasCustomUI + ui.
        let configURL = Self.appexResources(appURL).appendingPathComponent("runtime-config.json")
        let dict = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        #expect(dict?["hasCustomUI"] == nil)
        #expect(dict?["ui"] == nil)
    }

    @Test func exportWithMissingEntryHTMLFallsBackCleanly() throws {
        // Simulate a bundle whose manifest advertised a UI but whose
        // index.html was deleted: the exporter should log + carry on,
        // producing an export without ui/ and without hasCustomUI, rather
        // than throwing. The author fixes the missing file and re-exports.
        let fm = FileManager.default
        let emptyUI = fm.temporaryDirectory
            .appendingPathComponent("EmptyPresetUI_\(UUID().uuidString)")
            .appendingPathComponent("ui", isDirectory: true)
        try fm.createDirectory(at: emptyUI, withIntermediateDirectories: true)
        // Notice: no index.html inside emptyUI.

        let (outDir, regURL) = Self.tempOutputDir()
        defer {
            Self.cleanup(outDir.deletingLastPathComponent(), emptyUI.deletingLastPathComponent())
        }

        let payload = ExportManager.CustomUIPayload(
            directory: emptyUI, entryHTML: "index.html",
            width: nil, height: nil, fps: nil, audioFrames: false
        )
        let appURL = try Self.runExport(
            customUI: payload, outputDir: outDir, registryURL: regURL, name: "MissingEntryExport"
        )

        let exportedUIDir = Self.appexResources(appURL).appendingPathComponent("ui")
        #expect(!FileManager.default.fileExists(atPath: exportedUIDir.path))

        let configURL = Self.appexResources(appURL).appendingPathComponent("runtime-config.json")
        let dict = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        #expect(dict?["hasCustomUI"] == nil)
    }

    @Test func reExportOverwritesExistingUIDirectory() throws {
        // If the same name is exported twice with different UI contents, the
        // second export must fully replace the first one's ui/ — leftover
        // files from a prior export must not be carried over.
        let firstUI = try Self.makeFakeUIDirectory()
        let (outDir, regURL) = Self.tempOutputDir()
        defer {
            Self.cleanup(outDir.deletingLastPathComponent(), firstUI.deletingLastPathComponent())
        }

        _ = try Self.runExport(
            customUI: ExportManager.CustomUIPayload(
                directory: firstUI, entryHTML: "index.html",
                width: nil, height: nil, fps: nil, audioFrames: false),
            outputDir: outDir, registryURL: regURL, name: "ReExportTest"
        )

        // Second UI has a differently-named asset. After re-export, the
        // first UI's asset must be gone.
        let fm = FileManager.default
        let secondUIParent = fm.temporaryDirectory
            .appendingPathComponent("SecondPresetUI_\(UUID().uuidString)")
        let secondUI = secondUIParent.appendingPathComponent("ui", isDirectory: true)
        try fm.createDirectory(at: secondUI.appendingPathComponent("images"), withIntermediateDirectories: true)
        try "<!doctype html><title>v2</title>".write(
            to: secondUI.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try Data([0xFF, 0xD8, 0xFF]).write(to: secondUI.appendingPathComponent("images/logo.jpg"))
        defer { Self.cleanup(secondUIParent) }

        let appURL = try Self.runExport(
            customUI: ExportManager.CustomUIPayload(
                directory: secondUI, entryHTML: "index.html",
                width: nil, height: nil, fps: nil, audioFrames: false),
            outputDir: outDir, registryURL: regURL, name: "ReExportTest"
        )

        let exportedUIDir = Self.appexResources(appURL).appendingPathComponent("ui")
        // First export's CSS asset must be gone.
        #expect(!fm.fileExists(atPath: exportedUIDir.appendingPathComponent("assets/style.css").path))
        // Second export's image must be present.
        #expect(fm.fileExists(atPath: exportedUIDir.appendingPathComponent("images/logo.jpg").path))
    }
}
