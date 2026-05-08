import AppKit
import Foundation
import Testing
import WebKit

/// Tier-3 runtime validation: load a preset bundle's custom UI in an
/// offscreen WKWebView and verify it actually works. Catches failures
/// the static validator can't see — JS errors, custom elements that
/// fail to upgrade, `param=` references that look valid in the source
/// but don't resolve at runtime.
///
/// Lives in ConjureDSPTests because the smoke tester needs real
/// WebKit + NSWindow infrastructure, which the logic-only target
/// can't provide.
@MainActor
@Suite("BundleUISmokeTesterTests", .serialized)
struct BundleUISmokeTesterTests {

    // MARK: - Helpers

    /// Resolves the extension appex bundle — where customui-bridge.js
    /// and cdp-ui.js actually ship. The test target doesn't include
    /// those resources, so the smoke tester needs an explicit override.
    private static var resourceBundle: Bundle {
        get throws {
            guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
                throw TestError("builtInPlugInsURL is nil")
            }
            let appexURL = plugInsURL.appendingPathComponent("ConjureDSPExtension.appex")
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

    /// Build a throwaway `.cdp` bundle on disk with the provided
    /// manifest + UI HTML. Leaves the caller responsible for cleanup
    /// via `cleanup(_:)`.
    private static func makeBundle(
        manifest: String,
        uiHTML: String,
        entryScriptName: String = "process.py",
        entryScriptBody: String = "def process(ctx): pass\n"
    ) throws -> (PresetBundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmokeTest_\(UUID().uuidString).cdp", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try manifest.write(
            to: root.appendingPathComponent("manifest.json"),
            atomically: true, encoding: .utf8
        )
        try entryScriptBody.write(
            to: root.appendingPathComponent(entryScriptName),
            atomically: true, encoding: .utf8
        )
        let uiDir = root.appendingPathComponent("ui", isDirectory: true)
        try FileManager.default.createDirectory(at: uiDir, withIntermediateDirectories: true)
        try uiHTML.write(
            to: uiDir.appendingPathComponent("index.html"),
            atomically: true, encoding: .utf8
        )
        guard let bundle = PresetBundle.load(from: root) else {
            throw TestError("PresetBundle.load failed for \(root.path)")
        }
        return (bundle, root)
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Manifest with two params — what a real schema-v2 bundle looks
    /// like. Reused across tests that aren't specifically checking
    /// manifest edge cases.
    private let twoParamManifest = """
    {
      "schemaVersion": 2,
      "entry": "process.py",
      "language": "python",
      "params": [
        { "name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log" },
        { "name": "resonance", "min": 0.5, "max": 10.0, "default": 1.0, "unit": "Q" }
      ],
      "ui": {
        "entryHTML": "ui/index.html",
        "width": 400, "height": 240, "fps": 30, "audioFrames": false
      }
    }
    """

    // MARK: - Happy path

    @Test @MainActor func passesCleanBundle() async throws {
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <cdp-slider param="resonance"></cdp-slider>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired,
                "ConjureDSP.ready should fire once the bridge is loaded")
        #expect(report.jsErrors.filter { $0.kind == "error" || $0.kind == "unhandledrejection" || $0.kind == "harness" || $0.kind == "load" }.isEmpty,
                "no JS or load errors expected on a clean bundle; got: \(report.jsErrors)")
        #expect(report.components.count == 2)
        #expect(report.components.allSatisfy { $0.bound },
                "both cdp-sliders should bind against the declared params")
        #expect(report.params.allSatisfy { $0.hasInteractiveBinding },
                "every declared param has a matching cdp-slider")
        #expect(report.status == .pass)
    }

    // MARK: - Unbound component (the screenshot case)

    @Test @MainActor func flagsUnresolvedParamRef() async throws {
        // Agent wrote `param="modulation_depth"` but the manifest only
        // declares cutoff + resonance. The static validator already
        // catches this via `params_referenced_in_ui`, but the smoke
        // tester confirms the runtime symptom: the component fails to
        // bind and stays disabled.
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <cdp-slider param="modulation_depth"></cdp-slider>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        let unbound = report.components.first { !$0.bound }
        #expect(unbound != nil, "expected at least one unbound cdp-slider")
        #expect(unbound?.param == "modulation_depth")
        #expect(unbound?.reason?.contains("did not resolve") == true)
        #expect(report.status == .fail,
                "unbound components promote status to fail")
    }

    @Test @MainActor func flagsDeclaredParamWithNoUIBinding() async throws {
        // Both params declared in the manifest, but the UI only binds
        // one. `resonance` has no matching cdp-slider → user can see
        // the value reflected in the plugin but has no way to edit it
        // from the custom UI. Warning-level.
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        let resonance = report.params.first { $0.name == "resonance" }
        #expect(resonance?.hasInteractiveBinding == false)
        #expect(resonance?.reason?.contains("No cdp-*") == true)
        #expect(report.status == .warn,
                "missing binding is a warning, not a fail — UI still works, just incomplete")
    }

    // MARK: - JavaScript error capture

    @Test @MainActor func flagsRuntimeJSError() async throws {
        // Agent's inline script throws during init. The UI otherwise
        // looks fine — static validation couldn't catch this.
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <script>
            window.ConjureDSP.ready(function () {
              throw new Error("smoke test intentional throw");
            });
          </script>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        // Exceptions thrown inside a `ConjureDSP.ready(cb)` callback are
        // wrapped by the bridge's safeInvoke — they don't hit
        // window.onerror. Our harness captures them via the `log`
        // message channel and tags them as `callback_exception`.
        let errs = report.jsErrors.filter {
            $0.kind == "error" || $0.kind == "callback_exception"
        }
        #expect(errs.contains { $0.message.contains("smoke test intentional throw") },
                "the thrown error must surface in jsErrors; got: \(report.jsErrors)")
        #expect(report.status == .fail)
    }

    // MARK: - xy pad binding

    @Test @MainActor func cdpXYBindsBothAxes() async throws {
        let ui = """
        <!doctype html><html><body>
          <cdp-xy param-x="cutoff" param-y="resonance"></cdp-xy>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        let xy = report.components.first { $0.tag == "cdp-xy" }
        #expect(xy?.bound == true, "cdp-xy should bind both param-x and param-y")
        #expect(report.status == .pass)
    }

    // MARK: - Content overflow vs. manifest dimensions

    /// Manifest with a deliberately-tiny ui.height. Used by the
    /// overflow tests so we don't have to render a giant DOM to make
    /// content exceed declared.
    private let tinyUIManifest = """
    {
      "schemaVersion": 2,
      "entry": "process.py",
      "language": "python",
      "params": [
        { "name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log" }
      ],
      "ui": {
        "entryHTML": "ui/index.html",
        "width": 400, "height": 100, "fps": 30, "audioFrames": false
      }
    }
    """

    @Test @MainActor func reportsContentOverflowWhenHeightExceedsManifest() async throws {
        // Body content forces ~500pt of vertical layout against a
        // manifest that declared 100pt. The overflow block should
        // report `height` over by ~400.
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <cdp-slider param="cutoff"></cdp-slider>
          <div style="height: 500px; width: 10px;"></div>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: tinyUIManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff"],
            hostParameterCount: 1,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired,
                "ready must fire for overflow detection to run")
        let overflow = try #require(report.contentOverflow,
                "expected content_overflow to be populated when content exceeds declared height")
        #expect(overflow.overflows.contains("height"),
                "height axis should be flagged; got \(overflow.overflows)")
        #expect(overflow.declared.height == 100)
        // The 500pt spacer + cdp-slider host element should push the
        // rendered extent comfortably past the 100pt declared budget.
        // We assert ~400pt with a generous floor — exact pixels depend
        // on the slider's CSS height and WebKit's box model.
        let heightOver = overflow.byPixels.height ?? 0
        #expect(heightOver >= 350,
                "expected height overflow ~400pt; got \(heightOver)")
        #expect(overflow.rendered.height >= overflow.declared.height + heightOver)
    }

    @Test @MainActor func omitsContentOverflowWhenContentFits() async throws {
        // Manifest declares a generous 240pt height; the UI is a
        // single cdp-slider that lays out well under that. The
        // overflow block must be absent — present-but-empty would
        // mislead the agent into thinking there's a layout problem.
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <cdp-slider param="cutoff"></cdp-slider>
        </body></html>
        """
        let fitsManifest = """
        {
          "schemaVersion": 2,
          "entry": "process.py",
          "language": "python",
          "params": [
            { "name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log" }
          ],
          "ui": {
            "entryHTML": "ui/index.html",
            "width": 600, "height": 240, "fps": 30, "audioFrames": false
          }
        }
        """
        let (bundle, root) = try Self.makeBundle(manifest: fitsManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff"],
            hostParameterCount: 1,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        #expect(report.contentOverflow == nil,
                "content_overflow must be nil when the layout fits within the declared dimensions; got \(String(describing: report.contentOverflow))")
    }

    // MARK: - Text contrast pass

    @Test @MainActor func flagsLowContrastTextOnDarkBackground() async throws {
        // Author wrote dark text on a dark page background — exactly the
        // class of bug the static validator already catches as
        // body_text_contrast, but here we confirm the runtime probe sees
        // it too. Status downgrades to warn (not fail), since muted text
        // is sometimes intentional.
        let ui = """
        <!doctype html><html><body style="background: #1c1c20; color: #2a2a2e;">
          <p>Threshold</p>
          <cdp-slider param="cutoff"></cdp-slider>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        #expect(!report.lowContrastTexts.isEmpty,
                "expected at least one low-contrast text element; got \(report.lowContrastTexts)")
        let pIssue = report.lowContrastTexts.first { $0.selector.hasPrefix("p") }
        #expect(pIssue != nil, "the <p>Threshold</p> element should appear; got \(report.lowContrastTexts.map(\.selector))")
        #expect((pIssue?.ratio ?? 99) < 3.0,
                "ratio must be below the WCAG large-text threshold; got \(pIssue?.ratio ?? -1)")
        // Low contrast on its own (no JS errors, all params bound)
        // produces warn — not fail.
        #expect(report.status == .warn,
                "low contrast alone is a warning, not a fail; got \(report.status)")
    }

    @Test @MainActor func reportsNoContrastIssuesOnReadableBundle() async throws {
        // Explicit, high-contrast colors all the way down — should leave
        // lowContrastTexts empty and keep status at .pass. The
        // `color-scheme: dark` declaration is load-bearing: cdp-* widgets
        // resolve their text color through CanvasText, which paints
        // black on a dark background unless color-scheme is declared.
        let ui = """
        <!doctype html><html>
        <head><style>:root { color-scheme: dark; }</style></head>
        <body style="background: #111; color: #f5f5f5;">
          <p>Cutoff</p>
          <cdp-slider param="cutoff"></cdp-slider>
          <cdp-slider param="resonance"></cdp-slider>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        #expect(report.lowContrastTexts.isEmpty,
                "no contrast issues expected on a high-contrast bundle; got \(report.lowContrastTexts)")
        #expect(report.status == .pass)
    }

    @Test @MainActor func dedupesLowContrastIssuesBySelector() async throws {
        // Twenty <p> siblings all inherit the same bad color rule. The
        // probe caps at 10 issues but also dedupes by short selector, so
        // we expect just one entry for the whole group — not 10 copies.
        var paragraphs = ""
        for _ in 0..<20 { paragraphs += "<p>Threshold</p>" }
        let ui = """
        <!doctype html><html><body style="background: #1c1c20; color: #2a2a2e;">
          \(paragraphs)
          <cdp-slider param="cutoff"></cdp-slider>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        let pIssues = report.lowContrastTexts.filter { $0.selector.hasPrefix("p") }
        #expect(pIssues.count == 1,
                "twenty siblings sharing one selector should produce exactly one issue; got \(pIssues.count)")
    }

    // MARK: - console.log capture

    @Test @MainActor func capturesConsoleLogWithStringifiedObjects() async throws {
        let ui = """
        <!doctype html><html><body>
          <cdp-slider param="cutoff"></cdp-slider>
          <script>
            console.log("hello", {x: 1});
          </script>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        #expect(!report.consoleLogs.isEmpty,
                "expected at least one captured console.log entry; got \(report.consoleLogs)")
        let entry = report.consoleLogs.first { $0.contains("hello") }
        #expect(entry != nil,
                "expected a console.log entry containing the literal string; got \(report.consoleLogs)")
        #expect(entry?.contains("\"x\":1") == true || entry?.contains("\"x\": 1") == true,
                "object args must be JSON-stringified, not '[object Object]'; got \(String(describing: entry))")
        #expect(entry?.contains("[object Object]") == false,
                "stringification must avoid '[object Object]'; got \(String(describing: entry))")
    }

    // MARK: - Layout density / small-control checks

    @Test @MainActor func flagsTinySliderInSmallControls() async throws {
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <cdp-slider param="cutoff" style="width:30px"></cdp-slider>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        #expect(!report.smallControls.isEmpty,
                "expected small_controls to flag the 30px-wide slider; got \(report.smallControls)")
        let slider = report.smallControls.first { $0.tag == "cdp-slider" }
        #expect(slider != nil,
                "expected a cdp-slider entry in smallControls; got tags \(report.smallControls.map(\.tag))")
        #expect(slider?.param == "cutoff")
    }

    @Test @MainActor func flagsSparseLayoutWhenControlInCornerOfLargeCanvas() async throws {
        let sparseManifest = """
        {
          "schemaVersion": 2,
          "entry": "process.py",
          "language": "python",
          "params": [
            { "name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log" }
          ],
          "ui": {
            "entryHTML": "ui/index.html",
            "width": 600, "height": 400, "fps": 30, "audioFrames": false
          }
        }
        """
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <div style="position:absolute;left:0;top:0">
            <cdp-toggle param="cutoff" style="width:32px;height:18px"></cdp-toggle>
          </div>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: sparseManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff"],
            hostParameterCount: 1,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        let advisory = try #require(report.layoutAdvisory,
                "expected layout_advisory to be populated when interactive controls exist on a 600x400 canvas")
        #expect(advisory.coverageRatio < 0.20,
                "tiny corner control should have coverage_ratio well under 0.20; got \(advisory.coverageRatio)")
        #expect(advisory.flags.contains("sparse"),
                "sparse flag must live in layout_advisory.flags when coverage_ratio < 0.20; got \(advisory.flags)")
    }

    @Test @MainActor func flagsCdpSliderTrackSqueeze() async throws {
        let manifest = """
        {
          "schemaVersion": 2,
          "entry": "process.py",
          "language": "python",
          "params": [
            { "name": "foo", "min": 0.0, "max": 1.0, "default": 0.5, "unit": "" }
          ],
          "ui": {
            "entryHTML": "ui/index.html",
            "width": 400, "height": 240, "fps": 30, "audioFrames": false
          }
        }
        """
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <div style="width: 200px">
            <cdp-slider param="foo"></cdp-slider>
          </div>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: manifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "foo"],
            hostParameterCount: 1,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        let squeeze = report.smallControls.first { $0.reason == "track_squeezed" }
        #expect(squeeze != nil,
                "expected a smallControls entry with reason == \"track_squeezed\"; got \(report.smallControls)")
        #expect(squeeze?.param == "foo")
    }

    @Test @MainActor func flagsEmptyRegionViaCellCoverageGrid() async throws {
        let manifest = """
        {
          "schemaVersion": 2,
          "entry": "process.py",
          "language": "python",
          "params": [
            { "name": "a", "min": 0.0, "max": 1.0, "default": 0.5, "unit": "" },
            { "name": "b", "min": 0.0, "max": 1.0, "default": 0.5, "unit": "" },
            { "name": "c", "min": 0.0, "max": 1.0, "default": 0.5, "unit": "" }
          ],
          "ui": {
            "entryHTML": "ui/index.html",
            "width": 600, "height": 400, "fps": 30, "audioFrames": false
          }
        }
        """
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <div style="position:absolute;left:0;top:0;width:600px;height:100px;display:flex;flex-direction:row">
            <cdp-slider param="a" style="flex:1;height:100px"></cdp-slider>
            <cdp-slider param="b" style="flex:1;height:100px"></cdp-slider>
            <cdp-slider param="c" style="flex:1;height:100px"></cdp-slider>
          </div>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: manifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "a", 1: "b", 2: "c"],
            hostParameterCount: 3,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        let advisory = try #require(report.layoutAdvisory,
                "expected layout_advisory to be populated for a 600x400 canvas")
        #expect(!advisory.cellCoverage.isEmpty,
                "expected cell_coverage to be populated; got \(advisory.cellCoverage)")
        #expect(advisory.cellCoverage.count == 3,
                "expected 3 rows in cell_coverage; got \(advisory.cellCoverage.count)")
        if advisory.cellCoverage.count == 3 {
            let bottomRow = advisory.cellCoverage[2]
            #expect(bottomRow.count == 3,
                    "expected 3 cells in bottom row; got \(bottomRow.count)")
            for (idx, cov) in bottomRow.enumerated() {
                #expect(cov < 0.05,
                        "bottom row cell \(idx) should have coverage < 0.05; got \(cov)")
            }
        }
        #expect(advisory.flags.contains("empty_region"),
                "expected 'empty_region' flag in layout_advisory.flags when bottom row is empty; got \(advisory.flags)")
    }

    @Test @MainActor func skipsCellCoverageOnTinyCanvas() async throws {
        let manifest = """
        {
          "schemaVersion": 2,
          "entry": "process.py",
          "language": "python",
          "params": [
            { "name": "a", "min": 0.0, "max": 1.0, "default": 0.5, "unit": "" }
          ],
          "ui": {
            "entryHTML": "ui/index.html",
            "width": 200, "height": 60, "fps": 30, "audioFrames": false
          }
        }
        """
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <cdp-slider param="a"></cdp-slider>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: manifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "a"],
            hostParameterCount: 1,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        // Tiny canvases skip the cell-coverage grid entirely; the
        // advisory may still be populated (coverage_ratio / bbox_ratio
        // are useful), but cell_coverage must be empty and empty_region
        // must not be flagged.
        let cells = report.layoutAdvisory?.cellCoverage ?? []
        #expect(cells.isEmpty,
                "expected cell_coverage to be empty when canvas is below 100px in either dim; got \(cells)")
        let flags = report.layoutAdvisory?.flags ?? []
        #expect(!flags.contains("empty_region"),
                "expected 'empty_region' NOT to be flagged when grid is skipped; got \(flags)")
    }

    @Test @MainActor func cdpXYUnboundWhenAxisMissing() async throws {
        // param-y names a param that doesn't exist → xy pad doesn't
        // bind and drags move nothing.
        let ui = """
        <!doctype html><html><body>
          <cdp-xy param-x="cutoff" param-y="not_a_real_param"></cdp-xy>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        let xy = report.components.first { $0.tag == "cdp-xy" }
        #expect(xy?.bound == false)
        #expect(report.status == .fail)
    }

    @Test @MainActor func flagsCanvasWithZeroDrawingBuffer() async throws {
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <cdp-slider param="cutoff"></cdp-slider>
          <canvas id="x" style="width:200px;height:140px"></canvas>
          <script>
            var cv = document.getElementById('x');
            cv.width = 0;
            cv.height = 0;
          </script>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        #expect(!report.canvasIssues.isEmpty,
                "expected at least one canvas issue; got \(report.canvasIssues)")
        let zeroBuf = report.canvasIssues.first { $0.reason == "zero_buffer" }
        #expect(zeroBuf != nil,
                "expected a zero_buffer canvas issue; got \(report.canvasIssues)")
        #expect(zeroBuf?.id == "x")
        // canvas_zero_buffer is fully captured by `canvas_issues`. We
        // intentionally don't duplicate it as a layout-advisory flag —
        // hard issues stay in `canvas_issues`, soft observations live
        // in `layout_advisory.flags`.
        let advisoryFlags = report.layoutAdvisory?.flags ?? []
        #expect(!advisoryFlags.contains("canvas_zero_buffer"),
                "advisory flags should not duplicate hard canvas issues; got \(advisoryFlags)")
    }

    @Test @MainActor func cleanCanvasProducesNoIssues() async throws {
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <cdp-slider param="cutoff"></cdp-slider>
          <canvas id="y" style="width:400px;height:300px"></canvas>
          <script>
            var cv = document.getElementById('y');
            cv.width = 400;
            cv.height = 300;
          </script>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        #expect(report.canvasIssues.isEmpty,
                "expected no canvas issues on a properly-sized canvas; got \(report.canvasIssues)")
    }

    // MARK: - Advisory-vs-issues field shape

    /// Soft layout heuristics live ONLY under `layout_advisory`, never
    /// mixed into the top-level hard-issue arrays. That's the framing
    /// fix the 5/10 try-it agents flagged on 2026-05-08: they couldn't
    /// tell `sparse` / `clustered` / `empty_region` apart from a real
    /// warning when those shared shape with hard issues.
    ///
    /// This bundle deliberately triggers the layout heuristics (two
    /// short sliders cluster at the top of a 400×240 canvas, leaving
    /// an empty bottom region) — `status` still passes because nothing
    /// is genuinely broken, and the advisory flags surface only inside
    /// `layout_advisory.flags`.
    @Test @MainActor func passStatusKeepsSoftHeuristicsInAdvisoryBlock() async throws {
        let manifest = """
        {
          "schemaVersion": 2,
          "entry": "process.py",
          "language": "python",
          "params": [
            { "name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log" },
            { "name": "resonance", "min": 0.5, "max": 10.0, "default": 1.0, "unit": "Q" }
          ],
          "ui": {
            "entryHTML": "ui/index.html",
            "width": 400, "height": 240, "fps": 30, "audioFrames": false
          }
        }
        """
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <cdp-slider param="cutoff"></cdp-slider>
          <cdp-slider param="resonance"></cdp-slider>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: manifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        // Pass status: nothing broken — sliders bind, params covered,
        // no JS errors. Soft layout flags do not promote to warn/fail.
        #expect(report.status == .pass)
        // None of the top-level hard-issue arrays receive soft layout
        // signals — the reshape's whole point.
        #expect(report.canvasIssues.isEmpty,
                "canvas_issues must not pick up layout heuristics; got \(report.canvasIssues)")
        #expect(report.smallControls.isEmpty,
                "small_controls must not pick up layout heuristics; got \(report.smallControls)")
        #expect(report.lowContrastTexts.isEmpty,
                "low_contrast_texts must not pick up layout heuristics; got \(report.lowContrastTexts)")
        // The advisory block exists (coverage_ratio is informative),
        // and any soft flags the heuristics produced are nested inside
        // it — not at the top level alongside hard issues.
        let advisory = try #require(report.layoutAdvisory,
                "expected layout_advisory to be populated for an advisory-shaped bundle")
        // Sanity: the heuristics actually fired here. If they didn't,
        // the test would pass vacuously and not pin the reshape.
        #expect(!advisory.flags.isEmpty,
                "this bundle should trigger at least one advisory flag (sparse / clustered / empty_region); got \(advisory.flags)")
    }

    /// Encoded JSON shape: hard issues live at the top level, soft
    /// observations live under `layout_advisory`. Pins the wire shape
    /// MCP consumers receive — guards against an accidental future
    /// regression that re-promotes `coverage_ratio` / `layout_flags`
    /// to top-level keys (where they read as warnings).
    @Test @MainActor func reportJSONNestsAdvisoryUnderItsOwnKey() async throws {
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <cdp-slider param="cutoff"></cdp-slider>
          <cdp-slider param="resonance"></cdp-slider>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: twoParamManifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff", 1: "resonance"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        let data = try JSONEncoder().encode(report)
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "report must encode to a JSON object"
        )
        // Soft heuristics live ONLY under layout_advisory — never at
        // the top level alongside hard issue arrays.
        #expect(obj["coverage_ratio"] == nil,
                "coverage_ratio must not be a top-level key; got \(String(describing: obj["coverage_ratio"]))")
        #expect(obj["bbox_ratio"] == nil,
                "bbox_ratio must not be a top-level key; got \(String(describing: obj["bbox_ratio"]))")
        #expect(obj["layout_flags"] == nil,
                "layout_flags must not be a top-level key; got \(String(describing: obj["layout_flags"]))")
        #expect(obj["cell_coverage"] == nil,
                "cell_coverage must not be a top-level key; got \(String(describing: obj["cell_coverage"]))")
        // Hard issue arrays + diagnostic blocks stay at the top level.
        #expect(obj["canvas_issues"] != nil)
        #expect(obj["small_controls"] != nil)
        #expect(obj["js_errors"] != nil)
        // When advisory data is present, it nests cleanly. (May be
        // absent if there was no layout signal; but for this bundle
        // we expect at least coverage_ratio.)
        if let advisory = obj["layout_advisory"] as? [String: Any] {
            #expect(advisory["coverage_ratio"] != nil)
            #expect(advisory["bbox_ratio"] != nil)
            #expect(advisory["flags"] != nil)
        }
    }

    // MARK: - Canvas-aware empty_region suppression

    /// A UI that hands most of its real estate to a `<canvas>` (audio
    /// scope, spectrum analyzer, grain timeline) shouldn't be flagged
    /// as having an empty region just because the smoke tester never
    /// feeds audio so the canvas is blank. The canvas IS the visible
    /// surface; the area is intentionally reserved for a paint that
    /// only happens during playback.
    @Test @MainActor func canvasCoveredRegionDoesNotTriggerEmptyRegion() async throws {
        // 600x400 canvas. Two sliders span the top ~100pt; a 600x300
        // <canvas> fills the rest. Without canvas-aware suppression
        // the bottom row would be flagged 'empty_region' even though
        // it's deliberately occupied by the visualization.
        let manifest = """
        {
          "schemaVersion": 2,
          "entry": "process.py",
          "language": "python",
          "params": [
            { "name": "a", "min": 0.0, "max": 1.0, "default": 0.5, "unit": "" },
            { "name": "b", "min": 0.0, "max": 1.0, "default": 0.5, "unit": "" }
          ],
          "ui": {
            "entryHTML": "ui/index.html",
            "width": 600, "height": 400, "fps": 30, "audioFrames": false
          }
        }
        """
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <div style="position:absolute;left:0;top:0;width:600px;height:100px;display:flex;flex-direction:row">
            <cdp-slider param="a" style="flex:1;height:100px"></cdp-slider>
            <cdp-slider param="b" style="flex:1;height:100px"></cdp-slider>
          </div>
          <canvas id="scope" style="position:absolute;left:0;top:100px;width:600px;height:300px"></canvas>
          <script>
            var cv = document.getElementById('scope');
            cv.width = 600;
            cv.height = 300;
          </script>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: manifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "a", 1: "b"],
            hostParameterCount: 2,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        let advisoryFlags = report.layoutAdvisory?.flags ?? []
        #expect(!advisoryFlags.contains("empty_region"),
                "empty_region must not fire when the empty cells are covered by a canvas; got \(advisoryFlags)")
        #expect(!advisoryFlags.contains("sparse"),
                "sparse must not fire when a meaningful area is occupied by a canvas; got \(advisoryFlags)")
        #expect(report.canvasIssues.isEmpty,
                "the canvas itself should not generate canvas_issues — buffer is set correctly; got \(report.canvasIssues)")
    }

    /// Counter-test: an actually empty bottom row (no canvas, no
    /// controls) still gets flagged. Confirms the suppression is
    /// scoped to canvas-covered cells, not blanket.
    @Test @MainActor func emptyRegionStillFiresWithoutCanvas() async throws {
        let manifest = """
        {
          "schemaVersion": 2,
          "entry": "process.py",
          "language": "python",
          "params": [
            { "name": "a", "min": 0.0, "max": 1.0, "default": 0.5, "unit": "" },
            { "name": "b", "min": 0.0, "max": 1.0, "default": 0.5, "unit": "" },
            { "name": "c", "min": 0.0, "max": 1.0, "default": 0.5, "unit": "" }
          ],
          "ui": {
            "entryHTML": "ui/index.html",
            "width": 600, "height": 400, "fps": 30, "audioFrames": false
          }
        }
        """
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <div style="position:absolute;left:0;top:0;width:600px;height:100px;display:flex;flex-direction:row">
            <cdp-slider param="a" style="flex:1;height:100px"></cdp-slider>
            <cdp-slider param="b" style="flex:1;height:100px"></cdp-slider>
            <cdp-slider param="c" style="flex:1;height:100px"></cdp-slider>
          </div>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: manifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "a", 1: "b", 2: "c"],
            hostParameterCount: 3,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        let advisoryFlags = report.layoutAdvisory?.flags ?? []
        #expect(advisoryFlags.contains("empty_region"),
                "empty_region must still fire when the empty bottom is genuinely empty (no canvas); got \(advisoryFlags)")
    }

    /// A canvas positioned mostly off the manifest's declared canvas
    /// must not count toward `canvasArea` — otherwise authors could
    /// accidentally (or intentionally) suppress `sparse`/`clustered`
    /// advisories by parking a giant canvas at a negative offset where
    /// the user can't see it. Pins the clip-to-manifest fix from the
    /// Seer review.
    @Test @MainActor func offScreenCanvasDoesNotSuppressSparse() async throws {
        // 600x400 manifest. Tiny corner toggle — would normally trigger
        // `sparse` because coverage is < 0.20. A big <canvas> is
        // present, but it's positioned at left:-3000, top:-3000 so the
        // visible portion clipped to the manifest is zero. After the
        // fix, `canvasArea` should be ~0 and `sparse` should still
        // fire.
        let manifest = """
        {
          "schemaVersion": 2,
          "entry": "process.py",
          "language": "python",
          "params": [
            { "name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log" }
          ],
          "ui": {
            "entryHTML": "ui/index.html",
            "width": 600, "height": 400, "fps": 30, "audioFrames": false
          }
        }
        """
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <div style="position:absolute;left:0;top:0">
            <cdp-toggle param="cutoff" style="width:32px;height:18px"></cdp-toggle>
          </div>
          <canvas id="hidden" style="position:absolute;left:-3000px;top:-3000px;width:1200px;height:1200px"></canvas>
          <script>
            var cv = document.getElementById('hidden');
            cv.width = 1200;
            cv.height = 1200;
          </script>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: manifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff"],
            hostParameterCount: 1,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        let advisoryFlags = report.layoutAdvisory?.flags ?? []
        #expect(advisoryFlags.contains("sparse"),
                "sparse must still fire when a giant canvas is parked off-screen — clip-to-manifest should reduce its area to zero; got \(advisoryFlags)")
    }

    /// A canvas that hangs off the right edge of the manifest counts
    /// only for the visible portion. Pin: a 1000pt-wide canvas on a
    /// 600pt-wide manifest contributes 600pt of canvas area (clipped),
    /// not 1000pt. Verifies the partial-clip path of `clippedArea`.
    @Test @MainActor func partiallyOnScreenCanvasContributesClippedAreaOnly() async throws {
        // 600x400 manifest. The canvas extends from x=400 to x=1400 —
        // visible from 400→600 (200pt). With a 200pt-wide canvas at
        // y=100→400 (300pt high) the visible area is 200×300 = 60_000.
        // canvasFillRatio = 60_000 / (600×400 = 240_000) = 0.25, which
        // is ≥ 0.20 → canvasOccupied → suppresses sparse. If the JS
        // had used the raw 1000×300 = 300_000 area, the ratio would be
        // 1.25 — same outcome but on accidentally-inflated math.
        // Counter-test: shift the canvas further right so the visible
        // chunk drops below 20% and `sparse` fires.
        let manifest = """
        {
          "schemaVersion": 2,
          "entry": "process.py",
          "language": "python",
          "params": [
            { "name": "cutoff", "min": 20.0, "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log" }
          ],
          "ui": {
            "entryHTML": "ui/index.html",
            "width": 600, "height": 400, "fps": 30, "audioFrames": false
          }
        }
        """
        // Visible chunk: x=560→600 (40pt wide), y=100→400 (300pt tall)
        // → 40 × 300 = 12_000 / 240_000 = 0.05 < 0.20, NOT enough to
        // suppress. With unclipped math the canvas would be 1000×300 =
        // 300_000 / 240_000 = 1.25 — would suppress sparse and the
        // advisory would silently disappear.
        let ui = """
        <!doctype html><html><body style="margin:0;padding:0">
          <div style="position:absolute;left:0;top:0">
            <cdp-toggle param="cutoff" style="width:32px;height:18px"></cdp-toggle>
          </div>
          <canvas id="overflow" style="position:absolute;left:560px;top:100px;width:1000px;height:300px"></canvas>
          <script>
            var cv = document.getElementById('overflow');
            cv.width = 1000;
            cv.height = 300;
          </script>
        </body></html>
        """
        let (bundle, root) = try Self.makeBundle(manifest: manifest, uiHTML: ui)
        defer { Self.cleanup(root) }

        let report = await BundleUISmokeTester.run(
            bundle: bundle,
            hostParameterNames: [0: "cutoff"],
            hostParameterCount: 1,
            resourceBundle: try Self.resourceBundle
        )

        #expect(report.readyFired)
        let advisoryFlags = report.layoutAdvisory?.flags ?? []
        #expect(advisoryFlags.contains("sparse"),
                "sparse must fire when the on-screen slice of a partially-overflowing canvas is < 20% of the manifest; got \(advisoryFlags)")
    }
}
