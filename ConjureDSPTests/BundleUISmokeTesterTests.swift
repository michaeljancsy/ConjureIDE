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
        #expect(report.coverageRatio < 0.20,
                "tiny corner control should have coverage_ratio well under 0.20; got \(report.coverageRatio)")
        #expect(report.layoutFlags.contains("sparse"),
                "sparse flag must be set when coverage_ratio < 0.20; got \(report.layoutFlags)")
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
}
