import Foundation
import Testing

/// Tests for `BundleUIValidator` — the static lint that runs on
/// `write_bundle_file` / `validate_bundle` and surfaces custom-UI
/// authoring bugs before the agent claims done. Each test builds a
/// minimal `PresetBundle` on a temp dir, runs the validator, and
/// asserts the expected `check` shows up (or doesn't).
///
/// Lives in ConjureDSPTests (not Logic) so it can import the full
/// extension types — the validator depends on `PresetBundle`,
/// `PresetManifest`, and the manifest's v2 `params` shape.
struct BundleUIValidatorTests {

    // MARK: - Helpers

    /// Build a bundle on disk under a fresh temp dir and return its
    /// loaded `PresetBundle`. Caller supplies manifest JSON + optional
    /// ui/index.html content. The entry script is written as a stub so
    /// `PresetBundle.load` succeeds.
    private func makeBundle(
        manifest: String,
        uiHTML: String? = nil,
        entryScriptName: String = "process.py",
        entryScriptBody: String = "def process(i,o,f,s,p): pass\n"
    ) throws -> PresetBundle {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleUIValidatorTests-\(UUID().uuidString).cdp")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try manifest.write(
            to: tempRoot.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8
        )
        try entryScriptBody.write(
            to: tempRoot.appendingPathComponent(entryScriptName),
            atomically: true, encoding: .utf8
        )
        if let html = uiHTML {
            let uiDir = tempRoot.appendingPathComponent("ui")
            try FileManager.default.createDirectory(at: uiDir, withIntermediateDirectories: true)
            try html.write(
                to: uiDir.appendingPathComponent("index.html"),
                atomically: true, encoding: .utf8
            )
        }
        return try #require(PresetBundle.load(from: tempRoot))
    }

    /// v2 manifest with a single cutoff param + full ui block. Baseline
    /// for tests that only care about one thing at a time.
    private let baselineManifest = """
    {
      "schemaVersion": 2,
      "entry": "process.py",
      "language": "python",
      "params": [
        { "name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log" }
      ],
      "ui": {
        "entryHTML": "ui/index.html",
        "width": 400,
        "height": 240,
        "fps": 30,
        "audioFrames": false
      }
    }
    """

    private let baselineUI = """
    <!doctype html><html><head><meta charset="utf-8"></head>
    <body><cdp-slider param="cutoff"></cdp-slider></body></html>
    """

    // MARK: - Baseline + no-UI presets

    @Test func baselineBundlePasses() throws {
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: baselineUI)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.status == .pass, "baseline bundle should pass; issues: \(report.issues)")
        #expect(report.issues.isEmpty)
    }

    @Test func bundleWithoutUIPasses() throws {
        let manifest = """
        {"schemaVersion": 2, "entry": "process.py", "language": "python"}
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: nil)
        let report = BundleUIValidator.validate(bundle)
        // No UI block, no UI file — nothing to validate.
        #expect(report.status == .pass)
        #expect(report.issues.isEmpty)
    }

    // MARK: - manifest_ui_block_missing

    @Test func orphanUIFileFlagged() throws {
        // ui/index.html on disk but no ui block → fail.
        let manifest = """
        {"schemaVersion": 2, "entry": "process.py", "language": "python"}
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: baselineUI)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.status == .fail)
        #expect(report.issues.contains { $0.check == "manifest_ui_block_missing" })
    }

    // MARK: - ui_entry_html_missing

    @Test func manifestPointsAtNonexistentHTMLFlagged() throws {
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "ui": {"entryHTML": "ui/main.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: nil)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.status == .fail)
        #expect(report.issues.contains { $0.check == "ui_entry_html_missing" })
    }

    // MARK: - schema_v2_recommended

    @Test func schemaV1WithCustomUIWarned() throws {
        let manifest = """
        {
          "schemaVersion": 1, "entry": "process.py", "language": "python",
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: baselineUI)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "schema_v2_recommended" && $0.severity == .warn })
    }

    // MARK: - params_referenced_in_ui

    @Test func unresolvedParamReferenceFlagged() throws {
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <cdp-slider param="resonance"></cdp-slider>
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        let refIssues = report.issues.filter { $0.check == "params_referenced_in_ui" }
        #expect(refIssues.count == 1, "only 'resonance' is unresolved; cutoff is declared")
        #expect(refIssues.first?.message.contains("resonance") == true)
    }

    @Test func looseMatchAcceptsTitleCaseVariants() throws {
        // Python manifest key "low_gain" → Rust-emitted "Low Gain" in the UI
        // should still resolve. This is the single-UI-serves-both-langs
        // contract.
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "params": [
            {"name": "low_gain", "min": -12.0, "max": 12.0, "default": 0.0, "unit": "dB"}
          ],
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="Low Gain"></cdp-slider>
          <cdp-slider param="LOW_GAIN"></cdp-slider>
          <cdp-slider param="lowgain"></cdp-slider>
        </body></html>
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "params_referenced_in_ui" },
                "loose normalize should accept all three capitalizations")
    }

    @Test func numericParamIndexAllowed() throws {
        // param="0" is a valid numeric-index bind — no param name lookup
        // required.
        let ui = #"<!doctype html><html><body><cdp-slider param="0"></cdp-slider></body></html>"#
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "params_referenced_in_ui" })
    }

    @Test func xyPadAttributesChecked() throws {
        // Both param-x and param-y should resolve; param-y typo is flagged.
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "params": [
            {"name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz"},
            {"name": "resonance", "min": 0.5, "max": 10.0, "default": 1.0, "unit": "Q"}
          ],
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = #"<!doctype html><html><body><cdp-xy param-x="cutoff" param-y="resonanse"></cdp-xy></body></html>"#
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        let issue = report.issues.first { $0.check == "params_referenced_in_ui" }
        #expect(issue != nil, "typo 'resonanse' should be flagged")
        // Suggestion should point at the likely intended name.
        #expect(issue?.suggestion?.contains("resonance") == true)
    }

    // MARK: - external_asset_ref / network_egress_in_ui

    @Test func externalScriptFlagged() throws {
        let ui = """
        <!doctype html><html><head>
          <script src="https://cdn.jsdelivr.net/foo.js"></script>
        </head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.status == .fail)
        #expect(report.issues.contains { $0.check == "external_asset_ref" })
    }

    @Test func externalStylesheetFlagged() throws {
        let ui = """
        <!doctype html><html><head>
          <link rel="stylesheet" href="https://fonts.googleapis.com/css?family=Foo">
        </head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "external_asset_ref" })
    }

    @Test func relativeAssetNotFlagged() throws {
        // Relative paths go through the bundle scheme handler — fine.
        let ui = """
        <!doctype html><html><head>
          <link rel="stylesheet" href="assets/style.css">
          <script src="assets/app.js"></script>
        </head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "external_asset_ref" })
    }

    @Test func fetchCallFlagged() throws {
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <script>fetch("https://api.example.com/data").then(r => r.json());</script>
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "network_egress_in_ui" })
    }

    @Test func websocketFlagged() throws {
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <script>const s = new WebSocket("wss://example.com");</script>
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "network_egress_in_ui" })
    }

    // MARK: - canvas_system_color_literal

    @Test func canvasTextAssignmentFlagged() throws {
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <canvas id="c"></canvas>
          <script>
            const ctx = document.getElementById("c").getContext("2d");
            ctx.fillStyle = "CanvasText";
            ctx.strokeStyle = "color-mix(in srgb, CanvasText 50%, Canvas)";
          </script>
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        let canvasIssues = report.issues.filter { $0.check == "canvas_system_color_literal" }
        #expect(canvasIssues.count >= 1, "should flag CanvasText and color-mix(...)")
    }

    // MARK: - no_interactive_surface

    @Test func decorativeOnlyUIWithParamsWarned() throws {
        // No cdp-* components, no <input type=range>, no cdp-panel — but
        // the manifest declares 1 param. User can't edit it.
        let ui = """
        <!doctype html><html><body>
          <svg width="200" height="100"><circle cx="100" cy="50" r="30" fill="gold"/></svg>
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "no_interactive_surface" })
    }

    @Test func cdpPanelAutoSatisfiesSurfaceCheck() throws {
        let ui = #"<!doctype html><html><body><cdp-panel auto></cdp-panel></body></html>"#
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "no_interactive_surface" })
    }

    @Test func rangeInputSatisfiesSurfaceCheck() throws {
        let ui = #"<!doctype html><html><body><input type="range"></body></html>"#
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "no_interactive_surface" })
    }

    // MARK: - status aggregation

    @Test func statusFailIfAnyFail() throws {
        let ui = """
        <!doctype html><html><head>
          <script src="https://bad.example.com/x.js"></script>
        </head><body></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.status == .fail)
    }

    @Test func statusWarnIfOnlyWarnings() throws {
        // v1 schema + working UI → only the v2-recommended warning.
        let manifest = """
        {
          "schemaVersion": 1, "entry": "process.py", "language": "python",
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = #"<!doctype html><html><body><cdp-panel auto></cdp-panel></body></html>"#
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.status == .warn)
        #expect(report.issues.allSatisfy { $0.severity == .warn })
    }
}
