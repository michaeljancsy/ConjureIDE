//
//  ExportAUSizingTests.swift
//  ConjureDSPLogicTests
//
//  Asserts the window-sizing contract for the exported AU. Sizing is the
//  first thing users notice — if these go wrong, the debug pane ends up
//  cramped, the footer clips, or the debug view fails to take over the
//  window. Regression-prone because the SwiftUI layout math is all magic
//  numbers.
//
//  The file under test (`ExportAUWindowSizing.swift`) lives in the export
//  template's extension so it can also be called from the production view
//  controller. It's symlinked into this test directory — no local copy to
//  keep in sync.
//
//  Runs against the pure-static `ExportAUWindowSizing.computeSize(...)` so
//  we don't need to stand up an NSViewController for every assertion.
//

import AppKit
import Testing

@Suite("Export AU Window Sizing")
struct ExportAUSizingTests {
    /// Typical viewWidth used in production. Kept as a constant so tests
    /// stay readable.
    static let viewWidth: CGFloat = 500

    /// Regular layout with a handful of params gets a compact window —
    /// just the chrome + slider rows + footer.
    @Test func regularLayoutIsCompact() {
        let size = ExportAUWindowSizing.computeSize(
            showDebug: false,
            showError: false,
            hasCustomUI: false,
            customUIHeight: nil,
            paramCount: 4,
            viewWidth: Self.viewWidth
        )
        #expect(size.width == Self.viewWidth)
        #expect(size.height >= 150, "height below enforced minimum")
        #expect(size.height < 400, "regular 4-param layout shouldn't be 400pt+ tall")
    }

    /// Custom UI honors the manifest-declared height.
    @Test func customUIUsesManifestHeight() {
        let size = ExportAUWindowSizing.computeSize(
            showDebug: false,
            showError: false,
            hasCustomUI: true,
            customUIHeight: 400,
            paramCount: 8,
            viewWidth: Self.viewWidth
        )
        #expect(size.height >= 400, "custom UI body should at least be manifest height")
        #expect(size.height < 600, "chrome shouldn't inflate by more than ~200pt")
    }

    /// THE central regression check for the "debug pane is cramped"
    /// complaint. When debug is on, the window becomes tall enough to
    /// render a real log view — not a 360pt band under the params.
    @Test func showDebugReturnsTallWindow() {
        let regular = ExportAUWindowSizing.computeSize(
            showDebug: false,
            showError: false,
            hasCustomUI: false,
            customUIHeight: nil,
            paramCount: 1,
            viewWidth: Self.viewWidth
        )
        let withDebug = ExportAUWindowSizing.computeSize(
            showDebug: true,
            showError: false,
            hasCustomUI: false,
            customUIHeight: nil,
            paramCount: 1,
            viewWidth: Self.viewWidth
        )
        #expect(withDebug.height >= 600,
               "debug view needs a tall window, got \(withDebug.height)pt")
        #expect(withDebug.height > regular.height + 400,
               "debug window should be substantially taller than regular (regular=\(regular.height), debug=\(withDebug.height))")
    }

    /// The debug-window height is independent of param count — a 1-param
    /// preset with debug on shouldn't be visibly shorter than a 12-param
    /// preset with debug on. Without this invariant, the log would feel
    /// cramped on presets with fewer parameters.
    @Test func debugSizeIndependentOfParamCount() {
        let small = ExportAUWindowSizing.computeSize(
            showDebug: true,
            showError: false,
            hasCustomUI: false,
            customUIHeight: nil,
            paramCount: 1,
            viewWidth: Self.viewWidth
        )
        let large = ExportAUWindowSizing.computeSize(
            showDebug: true,
            showError: false,
            hasCustomUI: false,
            customUIHeight: nil,
            paramCount: 12,
            viewWidth: Self.viewWidth
        )
        #expect(small.height == large.height,
               "debug mode should use a fixed generous height regardless of param count")
    }

    /// A custom UI + debug should also use the tall debug height — the
    /// custom UI is hidden when debug is on, so its manifest height is
    /// irrelevant.
    @Test func debugOverridesCustomUIHeight() {
        let withCustomAndDebug = ExportAUWindowSizing.computeSize(
            showDebug: true,
            showError: false,
            hasCustomUI: true,
            customUIHeight: 200,  // deliberately small
            paramCount: 0,
            viewWidth: Self.viewWidth
        )
        #expect(withCustomAndDebug.height >= 600,
               "debug-on must ignore the custom UI's (possibly tiny) manifest height")
    }

    /// Error banner adds room when debug is OFF (debug encompasses the
    /// error in its log — no banner needed).
    @Test func errorBannerAddsRoomWhenDebugOff() {
        let base = ExportAUWindowSizing.computeSize(
            showDebug: false,
            showError: false,
            hasCustomUI: false,
            customUIHeight: nil,
            paramCount: 4,
            viewWidth: Self.viewWidth
        )
        let withError = ExportAUWindowSizing.computeSize(
            showDebug: false,
            showError: true,
            hasCustomUI: false,
            customUIHeight: nil,
            paramCount: 4,
            viewWidth: Self.viewWidth
        )
        #expect(withError.height > base.height,
               "error banner should add vertical room")
    }

    /// Error banner must ADD to the window, not subtract from the
    /// body. Window-with-error >= window-without-error + minBannerSize
    /// for the same custom UI height. Catches a "banner squeezes
    /// body" regression where the banner's budget gets shaved.
    @Test func errorBannerGrowsWindowForCustomUI() {
        let manifestHeight = 420
        let minBannerContribution: CGFloat = 150  // banner is budgeted 180pt

        let withoutError = ExportAUWindowSizing.computeSize(
            showDebug: false, showError: false,
            hasCustomUI: true, customUIHeight: manifestHeight,
            paramCount: 0, viewWidth: Self.viewWidth
        )
        let withError = ExportAUWindowSizing.computeSize(
            showDebug: false, showError: true,
            hasCustomUI: true, customUIHeight: manifestHeight,
            paramCount: 0, viewWidth: Self.viewWidth
        )
        let delta = withError.height - withoutError.height
        #expect(delta >= minBannerContribution,
               "error banner adds only \(delta)pt; should add at least \(minBannerContribution)pt so body isn't squeezed")
    }

    /// Slider layout overhead should stay roughly linear in param
    /// count. Catches per-param creep (e.g. someone inserts a
    /// divider between every slider and quietly doubles the vertical
    /// cost per row).
    @Test func sliderLayoutBodyScalesLinearly() {
        let s4 = ExportAUWindowSizing.computeSize(
            showDebug: false, showError: false,
            hasCustomUI: false, customUIHeight: nil,
            paramCount: 4, viewWidth: Self.viewWidth
        )
        let s8 = ExportAUWindowSizing.computeSize(
            showDebug: false, showError: false,
            hasCustomUI: false, customUIHeight: nil,
            paramCount: 8, viewWidth: Self.viewWidth
        )
        // 4 -> 8 params should add ~4 slider rows * ~28pt = ~112pt.
        // Anything outside 100-140pt is a signal that per-row cost
        // changed.
        let delta = s8.height - s4.height
        #expect(delta >= 100 && delta <= 140,
               "4->8 param delta \(delta)pt is out of expected 100-140pt band (per-row ~28pt * 4)")
    }

    /// Degenerate case (0 params, no custom UI) must floor at 150pt
    /// so the exported AU window isn't collapsed to invisibility.
    /// One-line regression guard for `max(height, 150)` in
    /// computeSize.
    @Test func windowHasSensibleMinimum() {
        let degenerate = ExportAUWindowSizing.computeSize(
            showDebug: false, showError: false,
            hasCustomUI: false, customUIHeight: nil,
            paramCount: 0, viewWidth: Self.viewWidth
        )
        #expect(degenerate.height >= 150,
               "degenerate case got \(degenerate.height)pt; floor is 150pt")
    }
}
