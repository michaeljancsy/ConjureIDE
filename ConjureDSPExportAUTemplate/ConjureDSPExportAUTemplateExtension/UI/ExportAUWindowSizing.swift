//
//  ExportAUWindowSizing.swift
//  ConjureDSPExportAUTemplateExtension
//
//  Pure sizing math extracted from ExportAUViewController so tests can call
//  it without standing up an NSViewController or the rest of the view
//  hierarchy. The caller (ExportAUViewController.computeSize(...)) forwards
//  to this static function; keeping the logic here makes it compilable into
//  the tests target alongside a handful of other AppKit-only files.
//

import AppKit

enum ExportAUWindowSizing {
    /// Compute the ideal window size for the exported AU. Values are
    /// conservative upper bounds — underestimating causes the title/gear to
    /// clip at the top or "Made with ConjureDSP" to disappear at the bottom
    /// when the DAW honors `preferredContentSize`.
    ///
    /// When `showDebug` is true, the view takes over the entire window (no
    /// sliders, no footer — just the debug pane). Returns a generous fixed
    /// height so Plugin Info / stats / log each get comfortable room. A
    /// small 360pt strip stacked under the slider stack, which the first
    /// attempt produced, was unreadable in practice.
    static func computeSize(
        showDebug: Bool,
        showError: Bool,
        hasCustomUI: Bool,
        customUIHeight: Int?,
        paramCount: Int,
        viewWidth: CGFloat
    ) -> NSSize {
        if showDebug {
            return NSSize(width: viewWidth, height: 720)
        }

        // Header = top padding (12) + title/gear row (~28 headline leading) +
        // VStack gap (12) before the divider.
        let headerHeight: CGFloat = 12 + 28 + 12
        // Divider itself.
        let dividerHeight: CGFloat = 1
        // Footer = VStack gap before footer (12) + caption2 line (~18) +
        // bottom padding (8). Plus ~4pt safety so Ableton's rounding doesn't
        // shave the last pixel.
        let footerHeight: CGFloat = 12 + 18 + 8 + 4
        // Gaps surrounding the body region (divider↔body↔footer/debug).
        let bodyGaps: CGFloat = 12 + 12
        let chromeHeight = headerHeight + dividerHeight + footerHeight + bodyGaps

        // Body region: either the preset's custom UI (manifest-declared
        // height, or a sensible default) or the generic slider stack
        // (~28pt per row).
        let bodyHeight: CGFloat
        if hasCustomUI {
            bodyHeight = CGFloat(customUIHeight ?? 320)
        } else {
            bodyHeight = CGFloat(paramCount) * 28
        }

        var height = chromeHeight + bodyHeight

        if showError {
            // Error banner: divider + header line + scrollable text area +
            // padding + VStack gap.
            height += 180
        }

        // Enforce minimum
        height = max(height, 150)

        return NSSize(width: viewWidth, height: height)
    }
}
