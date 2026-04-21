import Foundation
import Testing

/// Schema v2 of `manifest.json` adds a `params` block that lets the
/// manifest be the source of truth for parameter metadata. Pins the
/// parsing contract so factory presets (and user presets edited
/// externally) keep round-tripping.
struct PresetManifestSchemaV2Tests {

    @Test func v2ManifestWithParamsParses() throws {
        let json = """
        {
            "schemaVersion": 2,
            "entry": "process.rs",
            "language": "rust",
            "params": [
                {
                    "name": "cutoff",
                    "min": 20.0,
                    "max": 20000.0,
                    "default": 1000.0,
                    "unit": "Hz",
                    "curve": "log"
                },
                {
                    "name": "resonance",
                    "min": 0.5,
                    "max": 10.0,
                    "default": 1.0,
                    "unit": "Q"
                }
            ]
        }
        """.data(using: .utf8)!

        let manifest = try PresetManifest.decode(from: json)
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.params?.count == 2)
        #expect(manifest.params?.first?.name == "cutoff")
        #expect(manifest.params?.first?.curve == "log")
        #expect(manifest.params?.first?.min == 20.0)
        #expect(manifest.params?.first?.max == 20000.0)
        #expect(manifest.params?.last?.name == "resonance")
        #expect(manifest.params?.last?.unit == "Q")
    }

    @Test func v1ManifestStillParsesWithNilParams() throws {
        // v1 bundles on disk don't have a `params` field at all. The
        // manifest must decode cleanly and `params` must be nil so the
        // runtime knows to fall back to DSP-extracted metadata.
        let json = """
        {
            "schemaVersion": 1,
            "entry": "process.py",
            "language": "python"
        }
        """.data(using: .utf8)!

        let manifest = try PresetManifest.decode(from: json)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.params == nil)
    }

    @Test func paramDeclChoiceWithOptionsRoundTrips() throws {
        let json = """
        {
            "schemaVersion": 2,
            "entry": "process.py",
            "params": [
                {
                    "name": "mode",
                    "min": 0,
                    "max": 2,
                    "default": 1,
                    "unit": "",
                    "style": "choice",
                    "options": ["Low", "Mid", "High"]
                }
            ]
        }
        """.data(using: .utf8)!

        let manifest = try PresetManifest.decode(from: json)
        let p = manifest.params?.first
        #expect(p?.style == "choice")
        #expect(p?.options == ["Low", "Mid", "High"])
    }

    @Test func v2ManifestRoundTripsThroughEncode() throws {
        var original = PresetManifest(
            schemaVersion: 2,
            entry: "process.rs",
            language: "rust",
            ui: nil,
            params: [
                PresetManifest.ParamDecl(
                    name: "cutoff", key: nil, min: 20, max: 20000,
                    default: 1000, unit: "Hz", curve: "log", style: nil, options: nil
                )
            ],
            meta: nil
        )
        let data = try original.jsonData()
        let decoded = try PresetManifest.decode(from: data)
        #expect(decoded == original)
    }

    /// The two shipped SVF factory manifests (Python + Rust) must
    /// declare identical `params`. Catches accidental drift between
    /// variants (one side gets a range update, the other doesn't).
    @Test func svfPythonAndRustManifestsAgree() throws {
        let pythonURL = Self.factoryBundleURL("preset_svf")
            .appendingPathComponent("manifest.json")
        let rustURL = Self.factoryBundleURL("preset_svf_rust")
            .appendingPathComponent("manifest.json")
        let pyManifest = try PresetManifest.decode(from: Data(contentsOf: pythonURL))
        let rsManifest = try PresetManifest.decode(from: Data(contentsOf: rustURL))
        #expect(pyManifest.params == rsManifest.params,
                "SVF Python/Rust manifests diverged: py=\(String(describing: pyManifest.params)) rust=\(String(describing: rsManifest.params))")
    }

    // MARK: - helpers

    private static func factoryBundleURL(_ name: String) -> URL {
        // Walk back up from this source file to the repo root, then into
        // the ConjureDSPExtension/Resources/presets/ directory.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("ConjureDSPExtension")
            .appendingPathComponent("Resources")
            .appendingPathComponent("presets")
            .appendingPathComponent("\(name).cdp")
    }
}
