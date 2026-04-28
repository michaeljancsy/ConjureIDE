import Foundation
import Testing

/// Unit tests for `PresetBundle.loadResult(from:)` — the richer return
/// shape that distinguishes "not a bundle directory at all" from "is a
/// bundle but failed to parse." Drives the broken-bundle surfacing in
/// the preset browser + MCP.
struct PresetBundleLoadResultTests {

    // MARK: - Helpers

    /// Build a fresh temp dir for one test. Caller cleans up via
    /// `try? FileManager.default.removeItem(at:)`.
    private static func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetBundleLoadResultTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Write a valid manifest + entry script under `dir`, producing a bundle
    /// that `loadResult` should return as `.ok`.
    @discardableResult
    private static func writeValidBundle(at dir: URL, language: ScriptLanguage = .python) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = PresetBundle.defaultManifest(language: language, includeUI: false)
        try manifest.jsonData().write(to: dir.appendingPathComponent(PresetManifest.filename))
        try "def process(*args): pass\n".write(
            to: dir.appendingPathComponent(manifest.entry),
            atomically: true,
            encoding: .utf8
        )
        return dir
    }

    /// Write `bytes` to `dir/manifest.json` without ensuring it parses —
    /// used to construct the broken-manifest fixture.
    private static func writeRawManifest(at dir: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try contents.write(
            to: dir.appendingPathComponent(PresetManifest.filename),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Tests

    @Test func validBundleReturnsOk() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleDir = root.appendingPathComponent("MyPreset.cdp", isDirectory: true)
        try Self.writeValidBundle(at: bundleDir)

        let result = PresetBundle.loadResult(from: bundleDir)
        guard case .ok(let bundle) = result else {
            Issue.record("Expected .ok, got \(result)")
            return
        }
        #expect(bundle.name == "MyPreset")
    }

    @Test func brokenManifestJSONReturnsBroken() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleDir = root.appendingPathComponent("Hand Edited.cdp", isDirectory: true)
        // `"height": 00` — leading zeros are invalid JSON. Real-world
        // failure mode that prompted this work.
        try Self.writeRawManifest(at: bundleDir, contents: """
        {
          "schemaVersion": 2,
          "entry": "process.py",
          "ui": { "entryHTML": "ui/index.html", "width": 520, "height": 00 }
        }
        """)
        // Entry script exists — the failure is purely the manifest.
        try "def process(*args): pass\n".write(
            to: bundleDir.appendingPathComponent("process.py"),
            atomically: true,
            encoding: .utf8
        )

        let result = PresetBundle.loadResult(from: bundleDir)
        guard case .broken(let name, let rootURL, let error) = result else {
            Issue.record("Expected .broken, got \(result)")
            return
        }
        #expect(name == "Hand Edited")
        #expect(rootURL == bundleDir)
        // Error string includes the manifest path + a localized parse
        // description. We only assert the path is referenced — the JSON
        // decoder's exact wording is platform-stable enough but not
        // worth pinning verbatim.
        #expect(error.contains(PresetManifest.filename))
    }

    @Test func missingEntryScriptReturnsBroken() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleDir = root.appendingPathComponent("NoEntry.cdp", isDirectory: true)
        // Valid manifest, but the referenced entry script is absent.
        let manifest = PresetBundle.defaultManifest(language: .python, includeUI: false)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try manifest.jsonData().write(to: bundleDir.appendingPathComponent(PresetManifest.filename))

        let result = PresetBundle.loadResult(from: bundleDir)
        guard case .broken(let name, _, let error) = result else {
            Issue.record("Expected .broken, got \(result)")
            return
        }
        #expect(name == "NoEntry")
        #expect(error.contains("process.py"))
    }

    @Test func directoryWithoutManifestReturnsNotABundle() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("StrangerDir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hi\n".write(to: dir.appendingPathComponent("notes.txt"),
                         atomically: true, encoding: .utf8)

        #expect(PresetBundle.loadResult(from: dir) == .notABundle)
    }

    @Test func nonexistentPathReturnsNotABundle() {
        let bogus = URL(fileURLWithPath: "/tmp/PresetBundleLoadResultTests-does-not-exist-\(UUID().uuidString)")
        #expect(PresetBundle.loadResult(from: bogus) == .notABundle)
    }

    @Test func loadConvenienceReturnsNilForBrokenBundles() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleDir = root.appendingPathComponent("Broken.cdp", isDirectory: true)
        try Self.writeRawManifest(at: bundleDir, contents: "{ this isn't json")
        // Backward-compat: callers using the legacy `load` API still get
        // nil for broken bundles; the new shape is opt-in via loadResult.
        #expect(PresetBundle.load(from: bundleDir) == nil)
    }

    // MARK: - Discovery transformation
    //
    // PresetManager.discoverPresets walks the user-presets directory,
    // calls loadResult on each candidate, and produces a mix of working
    // and broken Preset entries. The full PresetManager pulls in the
    // extension's whole graph, so we replicate just the loop here to
    // assert the broken-keep behavior at a unit level.

    @Test func brokenBundlesSurviveDiscoveryTransform() throws {
        let root = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Fixture: one good bundle, one broken bundle, one stranger dir.
        let goodDir = root.appendingPathComponent("Good.cdp", isDirectory: true)
        try Self.writeValidBundle(at: goodDir)
        let brokenDir = root.appendingPathComponent("Broken.cdp", isDirectory: true)
        try Self.writeRawManifest(at: brokenDir, contents: "{ not json")
        // Need an entry script too so the bundle is "looksLikeBundle"
        // but the manifest decode fails.
        try "x".write(to: brokenDir.appendingPathComponent("process.py"),
                       atomically: true, encoding: .utf8)
        let strangerDir = root.appendingPathComponent("StrangerDir", isDirectory: true)
        try FileManager.default.createDirectory(at: strangerDir, withIntermediateDirectories: true)

        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var presets: [Preset] = []
        for url in entries {
            switch PresetBundle.loadResult(from: url) {
            case .ok(let bundle):
                presets.append(Preset(
                    id: "user:\(bundle.name)",
                    name: bundle.name,
                    source: .user(url: url),
                    factoryPresetNumber: nil,
                    language: bundle.language,
                    category: .other
                ))
            case .broken(let name, let rootURL, let error):
                presets.append(Preset(
                    id: "user:\(name)",
                    name: name,
                    source: .user(url: rootURL),
                    factoryPresetNumber: nil,
                    language: .python,
                    category: .other,
                    brokenError: error
                ))
            case .notABundle:
                continue
            }
        }

        // Both Good and Broken survive — and Broken is flagged as such.
        #expect(presets.count == 2)
        let good = presets.first(where: { $0.name == "Good" })
        let broken = presets.first(where: { $0.name == "Broken" })
        #expect(good != nil)
        #expect(good?.isBroken == false)
        #expect(broken != nil)
        #expect(broken?.isBroken == true)
        #expect(broken?.brokenError != nil)
    }
}
