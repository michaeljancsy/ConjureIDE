//
//  CustomUIParamSetCastTests.swift
//  ConjureDSPLogicTests
//
//  Pins the Swift language semantics that the custom-UI webview's
//  `paramSet` message handler depends on, and a source-level structural
//  check that the handlers actually USE the working pattern.
//
//  Concrete bug this exists to prevent (PR #255):
//
//  The export AU's webview parsed `body["value"]` as
//
//      let value = (body["value"] as? Double).map(Float.init)
//                  ?? (body["value"] as? Float)
//
//  which LOOKS equivalent to the in-extension version
//
//      if let d = body["value"] as? Double { value = Float(d) }
//      else if let f = body["value"] as? Float { value = f }
//      else { return }
//
//  but is not. Unlabeled `Float.init` lets Swift's overload resolution
//  pick the FAILABLE `Float.init?(exactly:)` initializer over the
//  non-failable narrowing init `Float.init(_ source: Double)`. For any
//  fractional Double that loses precision when narrowed to Float (e.g.
//  1002.6279…), `init?(exactly:)` returns nil. The `??` fallback
//  `as? Float` ALSO returns nil because NSNumber→Float bridging uses
//  the same exact-conversion check. The whole `guard let value = ...`
//  silently drops the message.
//
//  Symptom: the cdp-xy pad's cutoff drag posts ~150 fractional doubles
//  per second; every one was dropped, so the kernel only ever saw the
//  integer-valued extremes (20.0, 20000.0) the user's drag clamped to.
//  Audio "stuck on edge".
//
//  These tests catch the regression two ways:
//  1. Behavioral — encode a fractional NSNumber the way WebKit does and
//     run both cast forms; assert the failable form returns nil and the
//     explicit form returns the value.
//  2. Structural — grep the two paramSet handlers for `.map(Float.init)`
//     so a future refactor that reintroduces it fails the test even if
//     someone's manual smoke test happens to land on integer values.
//

import Foundation
import Testing

struct CustomUIParamSetCastTests {

    /// Pin the Swift type-inference behavior we depend on. The
    /// `.map(Float.init)` form selects the FAILABLE initializer; the
    /// explicit `Float(d)` form selects the non-failable narrowing one.
    /// If the language ever changes such that `.map(Float.init)` starts
    /// picking the non-failable overload, this test will fail and we'll
    /// know we can simplify the handler. Until then, the explicit form
    /// is the only one that round-trips fractional values.
    @Test func mapFloatInitDropsFractionalNSNumberWhileExplicitFloatPreserves() {
        // Reproduce what WebKit hands the Swift handler: a JS Number arrives
        // as an NSNumber-backed Double inside an [String: Any] dictionary.
        let fractional: Double = 1002.6279396825144
        let body: [String: Any] = ["index": 0, "value": NSNumber(value: fractional)]

        // The buggy form — document what it actually does, even though we
        // don't ship it. If this expectation fails, Swift now picks the
        // non-failable narrowing init for `.map(Float.init)`. Verify the
        // change is intentional before simplifying — today the failable
        // selection is what produced the cdp-xy "stuck on edge" bug.
        let buggyValue: Float? =
            (body["value"] as? Double).map(Float.init) ?? (body["value"] as? Float)
        #expect(buggyValue == nil,
                "Swift's `.map(Float.init)` no longer selects `init?(exactly:)`. Confirm intent before simplifying handlers.")

        // The shipping form — must round-trip.
        let goodValue: Float?
        if let d = body["value"] as? Double {
            goodValue = Float(d)
        } else if let f = body["value"] as? Float {
            goodValue = f
        } else {
            goodValue = nil
        }
        #expect(goodValue != nil,
                "Shipping cast pattern dropped a fractional Double — webview handlers would silently lose every cdp-xy drag value that isn't exactly representable as Float.")
        if let v = goodValue {
            // Float(1002.6279…) ≈ 1002.628 — narrowing loses precision but
            // not magnitude. Assert close-enough rather than exact equality.
            #expect(abs(Double(v) - fractional) < 0.01,
                    "Narrowed Float should be within 0.01 of the original Double.")
        }
    }

    /// Integer-valued JS Numbers were the only values that survived the
    /// buggy cast, which is why the bug looked like "drag snaps to edges":
    /// the user's drag clamped tx to 0 or 1, denormalize hit 20.0 or
    /// 20000.0, and those ARE exactly representable as Float so they
    /// passed the failable init?(exactly:). Pin that asymmetry so the
    /// next person reading these tests understands the failure mode.
    @Test func mapFloatInitPreservesExactlyRepresentableValues() {
        let body: [String: Any] = ["value": NSNumber(value: 20.0 as Double)]
        let v: Float? =
            (body["value"] as? Double).map(Float.init) ?? (body["value"] as? Float)
        #expect(v == 20.0,
                "Integer-valued doubles ARE exactly representable as Float — if this fails the asymmetry that caused the original bug no longer holds; recheck the bug story.")
    }

    /// Grep guard: both webview source files MUST use the explicit
    /// `Float(d)` form. If a future refactor reverts to `.map(Float.init)`,
    /// the behavioral test above catches it — but only on values that
    /// actually exercise the failable path. This static check fails
    /// regardless of test data, so the regression can't slip through on
    /// a manual smoke test that happened to land on 0/1.
    @Test func paramSetHandlersDoNotUseUnlabeledFloatInit() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ConjureDSPLogicTests/
            .deletingLastPathComponent()  // project root

        let handlers = [
            "ConjureDSPExtension/UI/CustomUIWebView.swift",
            "ConjureDSPExportAUTemplate/ConjureDSPExportAUTemplateExtension/UI/ExportCustomUIWebView.swift",
        ]

        for relPath in handlers {
            let url = projectRoot.appendingPathComponent(relPath)
            let source = try String(contentsOf: url, encoding: .utf8)

            // Find the paramSet handler region — bounded by `case "paramSet":`
            // and the next `case "` label. We only care about that block;
            // explanatory comments elsewhere in the file are fine.
            guard let caseStart = source.range(of: "case \"paramSet\":") else {
                Issue.record("\(relPath): no `case \"paramSet\":` found — handler shape changed?")
                continue
            }
            let afterCase = source[caseStart.upperBound...]
            let blockEnd = afterCase.range(of: "case \"")?.lowerBound ?? afterCase.endIndex
            let block = String(afterCase[..<blockEnd])

            // The forbidden pattern. `.map(Float.init)` and
            // `.map(Float.init(_:))` both select the failable overload via
            // type inference. We strip line comments and block-comment
            // markers before scanning so the explanatory comments that
            // reference the pattern (including in the very file we ship the
            // fix in) don't trigger this guard.
            let codeOnly = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                        return ""
                    }
                    return String(line)
                }
                .joined(separator: "\n")
            #expect(!codeOnly.contains(".map(Float.init"),
                    "paramSet handler uses `.map(Float.init…)` — see CustomUIParamSetCastTests file header for the bug story. Use `if let d = body[\"value\"] as? Double { Float(d) }`.")
        }
    }
}
