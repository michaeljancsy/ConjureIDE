import Foundation
import Testing

/// `ParamDecl.unit` is optional so manifests that declare style-only params
/// (e.g. `{"style": "toggle"}`) decode without a `keyNotFound("unit")`
/// failure. Pins the lenient contract — toggles, choices, and unitless
/// percentage controls have no meaningful display unit, and requiring one
/// just produces broken bundles when users hand-edit a manifest or an
/// older bundle is loaded.
struct PresetManifestParamDeclTests {

    @Test func paramDeclWithoutUnitDecodes() throws {
        let json = """
        {
            "schemaVersion": 2,
            "entry": "process.py",
            "params": [
                {"name": "bypass", "min": 0, "max": 1, "default": 0, "style": "toggle"}
            ]
        }
        """.data(using: .utf8)!

        let manifest = try PresetManifest.decode(from: json)
        let p = manifest.params?.first
        #expect(p?.name == "bypass")
        #expect(p?.style == "toggle")
        #expect(p?.unit == nil)
    }

    @Test func paramDeclWithExplicitUnitStillDecodes() throws {
        let json = """
        {
            "schemaVersion": 2,
            "entry": "process.py",
            "params": [
                {"name": "cutoff", "min": 20, "max": 20000, "default": 1000, "unit": "Hz"}
            ]
        }
        """.data(using: .utf8)!

        let manifest = try PresetManifest.decode(from: json)
        #expect(manifest.params?.first?.unit == "Hz")
    }
}
