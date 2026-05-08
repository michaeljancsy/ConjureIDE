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
        entryScriptBody: String = "def process(ctx): pass\n"
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

    /// Mid-authoring: manifest declares entryHTML but ui/ has no HTML
    /// files yet (or no ui/ directory at all). This is the standard
    /// save_preset → write manifest → write ui/index.html sequence,
    /// captured at step 2. Validator should warn, not fail — a `fail`
    /// here spooks literal-minded MCP agents into retrying or
    /// backtracking on what's actually transient state. The next
    /// write resolves it and a final validate_bundle pass returns
    /// clean.
    @Test func manifestPointsAtNonexistentHTMLWithEmptyUIDirWarnsOnly() throws {
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "ui": {"entryHTML": "ui/main.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: nil)
        let report = BundleUIValidator.validate(bundle)
        let entryIssue = report.issues.first { $0.check == "ui_entry_html_missing" }
        #expect(entryIssue != nil, "expected ui_entry_html_missing to fire")
        #expect(entryIssue?.severity == .warn, "empty ui/ is the transient mid-authoring case — should warn, not fail")
    }

    /// Real typo: ui/ contains other HTML files, but entryHTML names a
    /// different one. The author shipped some HTML, just not the one
    /// the manifest references. Validator should still fail — this is
    /// not transient state, it's a config bug that silently disables
    /// the custom UI.
    @Test func manifestPointsAtNonexistentHTMLWithOtherHTMLPresentFails() throws {
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "ui": {"entryHTML": "ui/main.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        // makeBundle writes uiHTML to ui/index.html. So manifest points at
        // ui/main.html, ui/ contains index.html — entryHTML typo.
        let bundle = try makeBundle(manifest: manifest, uiHTML: baselineUI)
        let report = BundleUIValidator.validate(bundle)
        let entryIssue = report.issues.first { $0.check == "ui_entry_html_missing" }
        #expect(entryIssue != nil, "expected ui_entry_html_missing to fire")
        #expect(entryIssue?.severity == .fail, "ui/ has other HTML — entryHTML typo is a real failure")
        #expect(entryIssue?.message.contains("index.html") == true, "fail message should list the HTML files actually present so the author can correct the typo")
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

    @Test func paramRefsInsideHTMLCommentsIgnored() throws {
        // The starter scaffold's example block lists hand-rolled bindings
        // like `<cdp-toggle param="Bypass">` inside an HTML comment so
        // authors can copy them out. They aren't real bindings; the
        // validator must not flag them. Reproduces the embedded-agent
        // turn that wasted a tool call rewriting the comment.
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "params": [
            {"name": "threshold", "min": -60.0, "max": 0.0, "default": -20.0, "unit": "dB"}
          ],
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="threshold"></cdp-slider>
          <!--
            Examples authors can copy:
              <cdp-toggle param="Bypass"></cdp-toggle>
              <cdp-choice param="Mode"></cdp-choice>
              <cdp-knob param="cutoff"></cdp-knob>
          -->
        </body></html>
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "params_referenced_in_ui" },
                "param=\"…\" inside <!-- ... --> must not be flagged")
    }

    @Test func paramRefsInsideHTMLCommentsIgnoredWhenNoManifestParams() throws {
        // Same comment-stripping rule applies in the no-manifest-params
        // branch — the starter scaffold ships v1 manifest + commented
        // examples, and that combination must be silent.
        let manifest = """
        {
          "schemaVersion": 1, "entry": "process.py", "language": "python",
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = """
        <!doctype html><html><body>
          <cdp-panel auto></cdp-panel>
          <!-- <cdp-toggle param="Bypass"></cdp-toggle> -->
          <!-- <cdp-knob param="cutoff"></cdp-knob> -->
        </body></html>
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "params_referenced_in_ui" },
                "no-manifest-params branch must also strip comments")
    }

    // MARK: - telemetry_referenced_in_ui

    /// Manifest baseline that declares one telemetry slot (`env_curve`,
    /// vector). UI references it correctly.
    private let telemetryManifest = """
    {
      "schemaVersion": 2,
      "entry": "process.py",
      "language": "python",
      "params": [
        { "name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log" }
      ],
      "telemetry": [
        { "name": "env_curve", "shape": "vector" },
        { "name": "gr_db", "shape": "scalar", "unit": "dB" }
      ],
      "ui": {
        "entryHTML": "ui/index.html",
        "width": 400,
        "height": 240,
        "fps": 30,
        "audioFrames": true
      }
    }
    """

    @Test func declaredTelemetryReferenceResolves() throws {
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <cdp-scope telemetry="env_curve"></cdp-scope>
        </body></html>
        """
        let bundle = try makeBundle(manifest: telemetryManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "telemetry_referenced_in_ui" },
                "declared telemetry name should resolve cleanly; issues: \(report.issues)")
    }

    @Test func unresolvedTelemetryReferenceFlagged() throws {
        // 'env_curv' is one char short — Levenshtein should snap to env_curve.
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <cdp-scope telemetry="env_curv"></cdp-scope>
        </body></html>
        """
        let bundle = try makeBundle(manifest: telemetryManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        let issue = report.issues.first { $0.check == "telemetry_referenced_in_ui" }
        #expect(issue != nil, "unresolved telemetry= should fire telemetry_referenced_in_ui")
        #expect(issue?.severity == .fail)
        #expect(issue?.message.contains("env_curv") == true)
        #expect(issue?.suggestion?.contains("env_curve") == true,
                "should suggest the nearest declared name")
    }

    @Test func telemetryLooseMatchAcceptsCaseAndUnderscoreVariants() throws {
        // Manifest declares `env_curve`; UI references should normalize
        // identically to the param= rule (case + underscore + space).
        let ui = """
        <!doctype html><html><body>
          <cdp-scope telemetry="ENV_CURVE"></cdp-scope>
          <cdp-scope telemetry="Env Curve"></cdp-scope>
          <cdp-scope telemetry="envcurve"></cdp-scope>
        </body></html>
        """
        let bundle = try makeBundle(manifest: telemetryManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "telemetry_referenced_in_ui" },
                "loose normalize should accept all three variants")
    }

    @Test func telemetryRefSkippedWhenManifestDeclaresNone() throws {
        // No manifest.telemetry block — runtime resolution is the spec'd
        // fallback. Static lint should NOT flag the reference.
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "params": [
            { "name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz" }
          ],
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": true}
        }
        """
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <cdp-scope telemetry="anything_at_all"></cdp-scope>
        </body></html>
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "telemetry_referenced_in_ui" },
                "missing manifest.telemetry → defer to runtime resolution, no static fail")
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

    @Test func xmlHttpRequestFlagged() throws {
        // The egress rule table includes XMLHttpRequest but no test covered
        // it. Pin here so regressions in the regex (e.g. whitespace change)
        // don't silently disable the check.
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <script>const xhr = new XMLHttpRequest(); xhr.open("GET", "/data");</script>
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "network_egress_in_ui" })
    }

    @Test func eventSourceFlagged() throws {
        // Symmetric to xhr/websocket — the rule is listed in the table but
        // untested.
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <script>const es = new EventSource("/events");</script>
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "network_egress_in_ui" })
    }

    @Test func externalImgFlagged() throws {
        // The external_asset_ref rule matches img/iframe/audio/video/source
        // too, not just script/link. Pin at least <img> since that's the
        // most common form preset authors reach for.
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <img src="https://cdn.example.com/logo.png">
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "external_asset_ref" })
    }

    @Test func protocolRelativeURLFlagged() throws {
        // `//example.com/x.js` is protocol-relative and reaches the network
        // just as surely as an `https:` URL. The CSP blocks it; the
        // validator rule regex includes `//` as a leading form.
        let ui = """
        <!doctype html><html><head>
          <script src="//evil.example.com/tracker.js"></script>
        </head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "external_asset_ref" })
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

    @Test func canvasPlainKeywordFlagged() throws {
        // The regex covers the bare "Canvas" keyword (the background-side
        // system color), not just "CanvasText". Both fail the same way in
        // Canvas 2D — silent fallback to transparent/black.
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <canvas id="c"></canvas>
          <script>
            const ctx = document.getElementById("c").getContext("2d");
            ctx.fillStyle = "Canvas";
          </script>
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "canvas_system_color_literal" })
    }

    @Test func canvasValidColorNotFlagged() throws {
        // Hex / rgb / named colors should never trip the system-color rule.
        // Prevents regex over-tightening from producing false positives on
        // perfectly legal canvas code.
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <canvas id="c"></canvas>
          <script>
            const ctx = document.getElementById("c").getContext("2d");
            ctx.fillStyle = "#3366aa";
            ctx.strokeStyle = "rgb(100, 200, 50)";
          </script>
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "canvas_system_color_literal" })
    }

    // MARK: - no_interactive_surface

    @Test func decorativeOnlyUIWithParamsFails() throws {
        // No cdp-* components, no <input type=range>, no cdp-panel — but
        // the manifest declares 1 param. User can't edit it.
        let ui = """
        <!doctype html><html><body>
          <svg width="200" height="100"><circle cx="100" cy="50" r="30" fill="gold"/></svg>
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        let issue = report.issues.first { $0.check == "no_interactive_surface" }
        #expect(issue != nil)
        #expect(issue?.severity == .fail)
        #expect(report.status == .fail)
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

    // MARK: - param_no_ui_binding (inverse coverage check)

    /// Two manifest params; UI binds only one. The unbound one should fail.
    @Test func declaredParamWithoutUIBindingFails() throws {
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "params": [
            {"name": "drive", "min": 1.0, "max": 20.0, "default": 5.0, "unit": "x"},
            {"name": "tone", "min": 200.0, "max": 20000.0, "default": 4000.0, "unit": "Hz", "curve": "log"}
          ],
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = #"<!doctype html><html><body><cdp-slider param="drive"></cdp-slider></body></html>"#
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        let issue = report.issues.first { $0.check == "param_no_ui_binding" }
        #expect(issue != nil, "tone is declared but not bound — should fail")
        #expect(issue?.severity == .fail, "every declared param must be reachable from the UI")
        #expect(issue?.message.contains("tone") == true)
        #expect(report.status == .fail)
    }

    /// All declared params bound — no warning.
    @Test func allParamsBoundNoWarning() throws {
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "params": [
            {"name": "drive", "min": 1.0, "max": 20.0, "default": 5.0, "unit": "x"},
            {"name": "tone", "min": 200.0, "max": 20000.0, "default": 4000.0, "unit": "Hz", "curve": "log"}
          ],
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="drive"></cdp-slider>
          <cdp-slider param="tone"></cdp-slider>
        </body></html>
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "param_no_ui_binding" })
    }

    /// `<cdp-panel auto>` is a catch-all that auto-renders one control per
    /// declared param — no warning even when no individual `<cdp-slider>`
    /// exists for each.
    @Test func cdpPanelAutoSuppressesUnboundWarning() throws {
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "params": [
            {"name": "drive", "min": 1.0, "max": 20.0, "default": 5.0, "unit": "x"},
            {"name": "tone", "min": 200.0, "max": 20000.0, "default": 4000.0, "unit": "Hz", "curve": "log"}
          ],
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = #"<!doctype html><html><body><cdp-panel auto></cdp-panel></body></html>"#
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "param_no_ui_binding" })
    }

    /// Loose-match resolution counts: "Low Gain" UI binding still satisfies
    /// "low_gain" manifest param.
    @Test func looseMatchedBindingCountsAsBound() throws {
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "params": [
            {"name": "low_gain", "min": -12.0, "max": 12.0, "default": 0.0, "unit": "dB"}
          ],
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = #"<!doctype html><html><body><cdp-slider param="Low Gain"></cdp-slider></body></html>"#
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "param_no_ui_binding" })
    }

    /// Numeric-index bindings count too: `param="0"` covers params[0].
    @Test func numericIndexBindingCountsAsBound() throws {
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "params": [
            {"name": "drive", "min": 1.0, "max": 20.0, "default": 5.0, "unit": "x"},
            {"name": "tone", "min": 200.0, "max": 20000.0, "default": 4000.0, "unit": "Hz"}
          ],
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="0"></cdp-slider>
          <cdp-slider param="1"></cdp-slider>
        </body></html>
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "param_no_ui_binding" })
    }

    /// XY-pad's `param-x` and `param-y` both count as bindings.
    @Test func xyPadBothAxesCountAsBound() throws {
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
        let ui = #"<!doctype html><html><body><cdp-xy param-x="cutoff" param-y="resonance"></cdp-xy></body></html>"#
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "param_no_ui_binding" })
    }

    /// Bundles with no manifest.params don't get the warning at all
    /// (legacy mode — we have nothing to compare against).
    @Test func noManifestParamsNoWarning() throws {
        let manifest = """
        {
          "schemaVersion": 2, "entry": "process.py", "language": "python",
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = #"<!doctype html><html><body><cdp-slider param="0"></cdp-slider></body></html>"#
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "param_no_ui_binding" })
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

    // MARK: - text_contrast_low / theme_breaking_body_color

    @Test func lowContrastInlineStyleFlagged() throws {
        // Dark gray text on dark gray background — clearly unreadable.
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <div style="color: #222; background: #333;">Illegible label</div>
        </body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "text_contrast_low" })
    }

    @Test func lowContrastCSSRuleFlagged() throws {
        // White-on-white inside a <style> block.
        let ui = """
        <!doctype html><html><head><style>
          .label { color: #fff; background-color: white; }
        </style></head>
        <body><cdp-slider param="cutoff"></cdp-slider><div class="label">Hi</div></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "text_contrast_low" })
    }

    @Test func rgbFunctionContrastFlagged() throws {
        let ui = """
        <!doctype html><html><head><style>
          .note { color: rgb(40, 40, 40); background: rgb(50, 50, 50); }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider><span class="note">x</span></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "text_contrast_low" })
    }

    @Test func hslLowContrastFlagged() throws {
        // Two very-dark HSLs with similar lightness.
        let ui = """
        <!doctype html><html><head><style>
          .bad { color: hsl(0, 0%, 10%); background: hsl(0, 0%, 15%); }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider><span class="bad">x</span></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "text_contrast_low" })
    }

    @Test func goodContrastNotFlagged() throws {
        // Black on white — WCAG 21:1, the gold standard.
        let ui = """
        <!doctype html><html><head><style>
          .ok { color: black; background: white; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider><span class="ok">x</span></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "text_contrast_low" })
    }

    @Test func themeAwareColorsNotFlagged() throws {
        // CanvasText on Canvas — the theme-correct pattern we recommend.
        // Validator should skip (can't know resolved colors statically).
        let ui = """
        <!doctype html><html><head><style>
          body { color: CanvasText; background: Canvas; }
          .label { color: CanvasText; background-color: Canvas; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "text_contrast_low" })
        #expect(!report.issues.contains { $0.check == "theme_breaking_body_color" })
    }

    @Test func themeBreakingHardcodedWhiteBodyFlagged() throws {
        // body uses theme-aware `background: Canvas` but hard-codes
        // light text — illegible in light mode.
        let ui = """
        <!doctype html><html><head><style>
          body { color: white; background: Canvas; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "theme_breaking_body_color" })
    }

    @Test func themeBreakingHardcodedBlackBodyFlagged() throws {
        // And the reverse — black text against Canvas is invisible in
        // dark mode.
        let ui = """
        <!doctype html><html><head><style>
          body { color: #000; background: Canvas; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "theme_breaking_body_color" })
    }

    @Test func themeBreakingNoBackgroundFlagged() throws {
        // No background declared at all — still theme-aware by default
        // (inherits Canvas). Same rule applies.
        let ui = """
        <!doctype html><html><head><style>
          body { color: white; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "theme_breaking_body_color" })
    }

    @Test func bodyWithExplicitMatchingBackgroundNotFlagged() throws {
        // If the author hard-codes BOTH text and background in concert,
        // that's a deliberate opt-out of theme-following — not a bug
        // for the body's own text. The contrast check verifies they're
        // legible together. (The cdp-ui-side trap that the author may
        // not realize they've stepped into — CanvasText-based theme
        // tokens still need a color-scheme declaration to follow the
        // hard-coded bg — is reported under `color_scheme_undeclared`.)
        let ui = """
        <!doctype html><html><head><style>
          body { color: white; background: #111; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        // theme_breaking should NOT fire (bg isn't Canvas-aware),
        // text_contrast_low should NOT fire (white on near-black is 20:1).
        #expect(!report.issues.contains { $0.check == "theme_breaking_body_color" })
        #expect(!report.issues.contains { $0.check == "text_contrast_low" })
    }

    // MARK: - color_scheme_undeclared

    @Test func darkBgWithoutColorSchemeFlagged() throws {
        // The exact case our cdp-meter preview hit: dark background,
        // no color-scheme declaration. cdp-ui slotted labels resolved
        // their muted color through `CanvasText` → black → invisible.
        let ui = """
        <!doctype html><html><head><style>
          body { color: #ddd; background: #1c1c20; }
        </style></head><body><cdp-meter source="peak-out"></cdp-meter></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "color_scheme_undeclared" })
    }

    @Test func lightBgWithoutColorSchemeFlagged() throws {
        // Reverse: hard-coded near-white bg with no `color-scheme: light`
        // would fire on a system in dark mode — CanvasText would resolve
        // to white, washed out against the page.
        let ui = """
        <!doctype html><html><head><style>
          body { color: #222; background: #f7f7f7; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "color_scheme_undeclared" })
    }

    @Test func darkBgWithMatchingColorSchemeNotFlagged() throws {
        // Author declared `color-scheme: dark` on :root — CanvasText
        // resolves to white, which is what we want against the dark bg.
        let ui = """
        <!doctype html><html><head><style>
          :root { color-scheme: dark; }
          body { color: #ddd; background: #1c1c20; }
        </style></head><body><cdp-meter source="peak-out"></cdp-meter></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "color_scheme_undeclared" })
    }

    @Test func darkBgWithMetaColorSchemeNotFlagged() throws {
        // The meta-tag form is equally valid — many authors reach for
        // it instead of CSS.
        let ui = """
        <!doctype html><html><head>
          <meta name="color-scheme" content="dark">
          <style>body { color: #ddd; background: #111; }</style>
        </head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "color_scheme_undeclared" })
    }

    @Test func darkBgWithSubstringOnlyColorSchemeStillFlagged() throws {
        // `highlight` contains the substring `light` but isn't a valid
        // `color-scheme` keyword. The check must tokenize on whitespace
        // and exact-match keywords — otherwise it false-negatives and
        // skips the warning. Spotted by Sentry Seer review on #266.
        let ui = """
        <!doctype html><html><head><style>
          :root { color-scheme: highlight; }
          body { color: #ddd; background: #111; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "color_scheme_undeclared" },
                "the `highlight` identifier should not satisfy the `dark` requirement")
    }

    @Test func darkBgWithReversedMetaAttributesNotFlagged() throws {
        // HTML attribute order is insignificant — `<meta content=".."
        // name="color-scheme">` is just as valid as the canonical order.
        // Regression: the original regex pinned `name` before `content`
        // and false-positived on this form (Sentry Seer review on #266).
        let ui = """
        <!doctype html><html><head>
          <meta content="dark" name="color-scheme">
          <style>body { color: #ddd; background: #111; }</style>
        </head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "color_scheme_undeclared" })
    }

    @Test func lightDarkColorSchemeAcceptsEither() throws {
        // `color-scheme: light dark` lets the system choose; either
        // direction should pass.
        let ui = """
        <!doctype html><html><head><style>
          :root { color-scheme: light dark; }
          body { background: #111; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "color_scheme_undeclared" })
    }

    @Test func canvasBgNotFlagged() throws {
        // Theme-aware background (Canvas) by definition follows the
        // system color-scheme. No declaration needed.
        let ui = """
        <!doctype html><html><head><style>
          body { background: Canvas; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "color_scheme_undeclared" })
    }

    @Test func midGreyBgNotFlagged() throws {
        // A mid-grey background (luminance ~0.4) is ambiguous — the
        // author hasn't picked a side. Don't fire.
        let ui = """
        <!doctype html><html><head><style>
          body { background: #888; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "color_scheme_undeclared" })
    }

    // MARK: - params_referenced_in_ui — no-manifest-params branch

    @Test func namedParamRefWithoutManifestParamsFlagged() throws {
        // UI has `param="cutoff"` but manifest is v1 (no params block).
        // Every cdp-slider will render with an "unknown" label until the
        // user adds a manifest.params declaration — the exact failure
        // mode the live-plugin screenshot showed.
        let manifest = """
        {
          "schemaVersion": 1,
          "entry": "process.py",
          "language": "python",
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <cdp-slider param="resonance"></cdp-slider>
          <cdp-xy param-x="lfo_rate" param-y="depth"></cdp-xy>
        </body></html>
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        let issue = report.issues.first { $0.check == "params_referenced_in_ui" }
        #expect(issue != nil, "named param refs with no manifest.params should be flagged")
        #expect(issue?.severity == .fail)
        // The message should mention the refs that can't be resolved.
        let msg = issue?.message ?? ""
        #expect(msg.contains("\"cutoff\"") || msg.contains("\"resonance\"") ||
                msg.contains("\"lfo_rate\"") || msg.contains("\"depth\""))
    }

    @Test func numericParamRefWithoutManifestParamsNotFlagged() throws {
        // param="0", param="1" bind by index — no manifest.params lookup
        // required, so no flag regardless of whether params is declared.
        let manifest = """
        {
          "schemaVersion": 1,
          "entry": "process.py",
          "language": "python",
          "ui": {"entryHTML": "ui/index.html", "width": 400, "height": 240, "fps": 30, "audioFrames": false}
        }
        """
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="0"></cdp-slider>
          <cdp-slider param="1"></cdp-slider>
        </body></html>
        """
        let bundle = try makeBundle(manifest: manifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "params_referenced_in_ui" })
    }

    // MARK: - text_contrast_low — cascaded (cross-rule) pair check

    @Test func cascadedDarkColorOnDarkBodyFlagged() throws {
        // The screenshot-from-the-wild case: body has a dark background
        // declared in its own rule, a descendant has a dark color in a
        // separate rule. Same-block check misses this; cascade check
        // catches it.
        let ui = """
        <!doctype html><html><head><style>
          body { background: #0a0a0a; }
          .label { color: #555; }
        </style></head>
        <body><cdp-slider param="cutoff"></cdp-slider><span class="label">Mix</span></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        let issue = report.issues.first { $0.check == "text_contrast_low" }
        #expect(issue != nil, "cross-rule dark-on-dark should be flagged")
        // Message should mention the inherited side.
        #expect(issue?.message.contains("inherited from body") == true)
    }

    @Test func cascadedLightOnLightFlagged() throws {
        // Symmetric: body's light hardcoded background + descendant's
        // light hardcoded text.
        let ui = """
        <!doctype html><html><head><style>
          html, body { background: #f8f8f8; }
          .subtle { color: #e0e0e0; }
        </style></head>
        <body><cdp-slider param="cutoff"></cdp-slider><span class="subtle">x</span></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "text_contrast_low" })
    }

    @Test func cascadedBackgroundOnlyFlaggedAgainstBodyColor() throws {
        // Reverse side of the cascade: body declares a text color and a
        // descendant declares a clashing background without its own color.
        let ui = """
        <!doctype html><html><head><style>
          body { color: #eeeeee; }
          .card { background: #f5f5f5; }
        </style></head>
        <body><cdp-slider param="cutoff"></cdp-slider><div class="card">x</div></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(report.issues.contains { $0.check == "text_contrast_low" })
    }

    @Test func cascadedContrastSkipsThemeAwareBase() throws {
        // If the body background is theme-aware (Canvas), we can't know
        // the resolved luminance statically — skip the pair check. The
        // theme_breaking_body_color rule handles obvious body-level
        // failures; descendant-only clashes against Canvas fall through
        // deliberately.
        let ui = """
        <!doctype html><html><head><style>
          body { background: Canvas; }
          .label { color: #555; }
        </style></head>
        <body><cdp-slider param="cutoff"></cdp-slider><span class="label">x</span></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "text_contrast_low" },
                "cascaded check should not fire when base is theme-aware")
    }

    @Test func cascadedContrastSkipsBodyItself() throws {
        // The page-level rule's own color/background pair is covered by
        // the in-block pair check. Don't double-flag it via the cascade
        // branch.
        let ui = """
        <!doctype html><html><head><style>
          body { color: white; background: #111; }
        </style></head><body><cdp-slider param="cutoff"></cdp-slider></body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)
        let report = BundleUIValidator.validate(bundle)
        let contrast = report.issues.filter { $0.check == "text_contrast_low" }
        // white on #111 is ~18:1 — neither branch should flag this.
        #expect(contrast.isEmpty)
    }

    // MARK: - Performance / scale

    @Test func largeUIValidatesInBoundedTime() throws {
        // 500 cdp-slider rows + a sizeable <style> block — well beyond any
        // real preset UI but small enough to fit in-memory. Validates in
        // well under a second; pinning at 5s so CI variance doesn't flake.
        var body = ""
        for i in 0..<500 {
            body += "<cdp-slider param=\"cutoff\" label=\"P\(i)\"></cdp-slider>\n"
        }
        var style = ""
        for i in 0..<200 {
            style += ".row\(i) { color: #\(String(format: "%06x", i * 113 % 0xffffff)); background: #fff; }\n"
        }
        let ui = """
        <!doctype html><html><head><style>\(style)</style></head>
        <body>\(body)</body></html>
        """
        let bundle = try makeBundle(manifest: baselineManifest, uiHTML: ui)

        let start = Date()
        let report = BundleUIValidator.validate(bundle)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 5.0, "validator took \(elapsed)s on a 500-component UI — regex backtracking?")
        // Report should be well-formed regardless of issue count.
        #expect([.pass, .warn, .fail].contains(report.status))
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

    // MARK: - state_key_referenced_in_ui

    /// Baseline: HTML refers to a STATE key declared in the script's
    /// `STATE = {…}` dict — no issue is emitted.
    @Test func declaredStateKeyResolves() throws {
        let scriptBody = """
        STATE = {"declared_key": 0}

        def process(ctx):
            pass
        """
        let ui = """
        <!doctype html><html><body>
        <cdp-slider param="cutoff"></cdp-slider>
        <script>
          ConjureDSP.ready(() => {
            const v = ConjureDSP.state.get('declared_key');
            ConjureDSP.state.set('declared_key', v);
          });
        </script>
        </body></html>
        """
        let bundle = try makeBundle(
            manifest: baselineManifest,
            uiHTML: ui,
            entryScriptName: "process.py",
            entryScriptBody: scriptBody
        )
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "state_key_referenced_in_ui" },
                "declared key 'declared_key' must resolve cleanly; issues: \(report.issues)")
    }

    /// Typo case: the UI references a key that doesn't exist in the
    /// script's STATE dict. Validator must fail and offer the nearest
    /// declared name as a "did you mean" hint.
    @Test func unresolvedStateKeyFlaggedWithSuggestion() throws {
        let scriptBody = """
        STATE = {"declared_key": 0}

        def process(ctx):
            pass
        """
        // Typo: declared_kye. Levenshtein distance 1 from declared_key.
        let ui = """
        <!doctype html><html><body>
        <cdp-slider param="cutoff"></cdp-slider>
        <script>
          ConjureDSP.state.set('declared_kye', 1);
        </script>
        </body></html>
        """
        let bundle = try makeBundle(
            manifest: baselineManifest,
            uiHTML: ui,
            entryScriptName: "process.py",
            entryScriptBody: scriptBody
        )
        let report = BundleUIValidator.validate(bundle)
        let issue = report.issues.first { $0.check == "state_key_referenced_in_ui" }
        #expect(issue != nil, "typo 'declared_kye' must be flagged; got \(report.issues)")
        #expect(issue?.severity == .fail)
        #expect(issue?.suggestion?.contains("declared_key") == true,
                "suggestion must point at the nearest declared name; got \(issue?.suggestion ?? "<nil>")")
    }

    /// Dynamic-key references — first arg isn't a literal — are
    /// silently skipped because we can't statically resolve the key.
    @Test func dynamicStateKeyReferenceSkipped() throws {
        let scriptBody = """
        STATE = {"declared_key": 0}

        def process(ctx):
            pass
        """
        let ui = """
        <!doctype html><html><body>
        <cdp-slider param="cutoff"></cdp-slider>
        <script>
          var myVar = 'whatever';
          ConjureDSP.state.set(myVar, 1);
        </script>
        </body></html>
        """
        let bundle = try makeBundle(
            manifest: baselineManifest,
            uiHTML: ui,
            entryScriptName: "process.py",
            entryScriptBody: scriptBody
        )
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "state_key_referenced_in_ui" },
                "dynamic-key references (non-literal first arg) must be silently skipped")
    }

    /// Backtick template-literal quoting must resolve the same way as
    /// single / double quotes. People template-literal these "for no
    /// real reason" all the time.
    @Test func backtickQuotedStateKeyResolves() throws {
        let scriptBody = """
        STATE = {"backtick_key": 0}

        def process(ctx):
            pass
        """
        let ui = """
        <!doctype html><html><body>
        <cdp-slider param="cutoff"></cdp-slider>
        <script>
          const v = ConjureDSP.state.get(`backtick_key`);
        </script>
        </body></html>
        """
        let bundle = try makeBundle(
            manifest: baselineManifest,
            uiHTML: ui,
            entryScriptName: "process.py",
            entryScriptBody: scriptBody
        )
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "state_key_referenced_in_ui" },
                "backtick-quoted state key must resolve; issues: \(report.issues)")
    }

    /// Both single-quote and double-quote forms must work. (The
    /// regex shouldn't be biased toward one quote style.)
    @Test func bothQuoteStylesResolveStateKeys() throws {
        let scriptBody = """
        STATE = {"foo": 0, "bar": 0}

        def process(ctx):
            pass
        """
        let ui = """
        <!doctype html><html><body>
        <cdp-slider param="cutoff"></cdp-slider>
        <script>
          ConjureDSP.state.set("foo", 1);
          ConjureDSP.state.set('bar', 2);
        </script>
        </body></html>
        """
        let bundle = try makeBundle(
            manifest: baselineManifest,
            uiHTML: ui,
            entryScriptName: "process.py",
            entryScriptBody: scriptBody
        )
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "state_key_referenced_in_ui" },
                "both quote styles must resolve declared state keys; issues: \(report.issues)")
    }

    /// Bug-report shape: STATE dict with list values + a scalar value.
    /// The Python parser must extract top-level keys without choking on
    /// list / dict literals in the value position, and must not emit
    /// `state_keys_unparseable` for this textbook shape.
    @Test func listAndScalarStateValuesResolve() throws {
        let scriptBody = """
        STATE = {
            "snap_cutoff":    [1000.0, 1000.0, 1000.0, 1000.0],
            "snap_resonance": [0.707,  0.707,  0.707,  0.707],
            "active":         0,
        }

        def process(ctx):
            pass
        """
        let ui = """
        <!doctype html><html><body>
        <cdp-slider param="cutoff"></cdp-slider>
        <script>
          ConjureDSP.ready(() => {
            const c = ConjureDSP.state.get('snap_cutoff') || [];
            const r = ConjureDSP.state.get('snap_resonance') || [];
            const a = ConjureDSP.state.get('active');
            ConjureDSP.state.set('snap_cutoff', c);
            ConjureDSP.state.set('snap_resonance', r);
            ConjureDSP.state.set('active', a);
          });
        </script>
        </body></html>
        """
        let bundle = try makeBundle(
            manifest: baselineManifest,
            uiHTML: ui,
            entryScriptName: "process.py",
            entryScriptBody: scriptBody
        )
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "state_keys_unparseable" },
                "list/dict-valued STATE keys must parse cleanly; issues: \(report.issues)")
        #expect(!report.issues.contains { $0.check == "state_key_referenced_in_ui" },
                "all referenced keys are declared and must resolve; issues: \(report.issues)")
    }

    /// Rust scripts use a dynamic raw-bytes STATE channel — there are no
    /// statically-declared keys for the validator to compare UI
    /// references against. The validator must not emit
    /// `state_keys_unparseable` (false-positive warn) or
    /// `state_key_referenced_in_ui` (false-positive fail) for any UI
    /// `ConjureDSP.state.*` reference paired with a `state!()` Rust
    /// script.
    @Test func rustStateMacroSkipsLint() throws {
        let manifest = """
        {
          "schemaVersion": 2,
          "entry": "process.rs",
          "language": "rust",
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
        let scriptBody = """
        use conjuredsp::*;
        setup!();
        params! { CUTOFF = freq() }
        state!();

        #[no_mangle]
        pub extern "C" fn process(frame_count: u32, sample_rate: f32) {
            let _cx = ctx(frame_count, sample_rate);
        }
        """
        let ui = """
        <!doctype html><html><body>
        <cdp-slider param="cutoff"></cdp-slider>
        <script>
          ConjureDSP.ready(() => {
            const v = ConjureDSP.state.get('whatever_key');
            ConjureDSP.state.set('whatever_key', v);
          });
        </script>
        </body></html>
        """
        let bundle = try makeBundle(
            manifest: manifest,
            uiHTML: ui,
            entryScriptName: "process.rs",
            entryScriptBody: scriptBody
        )
        let report = BundleUIValidator.validate(bundle)
        #expect(!report.issues.contains { $0.check == "state_keys_unparseable" },
                "Rust scripts must not trigger state_keys_unparseable; issues: \(report.issues)")
        #expect(!report.issues.contains { $0.check == "state_key_referenced_in_ui" },
                "Rust scripts use a dynamic byte API; UI state.* references must not be flagged; issues: \(report.issues)")
    }
}
