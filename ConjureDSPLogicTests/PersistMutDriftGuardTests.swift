//
//  PersistMutDriftGuardTests.swift
//  ConjureDSPLogicTests
//
//  Drift guard for the user-facing teaching surfaces that the
//  persist_buf! → persist_mut! rename touched. Asserts three patterns
//  are absent from each:
//
//  (a) Literal `persist_buf` / `PersistBuf` — catches a missed rename.
//
//  (b) `persist!(NAME: Lfo|Biquad|DelayLine ...)` — the tier-2
//      contradiction class. The new choosing rule routes DSP blocks
//      whose &mut self methods are the natural usage shape
//      (Biquad::process_sample, Lfo::tick, DelayLine::write) through
//      persist_mut!, not persist!. A passing rename grep could still
//      leave `persist!(BIQUADS: [Biquad; 2] = …)` in place — that's the
//      failure mode this regex catches.
//
//  (c) `[Lfo|Biquad|DelayLine::new(); N]` array-repeat literal — the
//      Copy-removal class. `Biquad` / `Lfo` / `DelayLine` no longer
//      derive `Copy`, so the bare array-repeat literal fails with
//      `E0277: T: Copy is not satisfied`. Authors must wrap in an
//      inline-const block: `[const { Biquad::new() }; N]`. A reviewer
//      caught four occurrences of the broken form in DSPDocumentation
//      and PTYManager teaching surfaces that the original rewrite
//      missed — this regex prevents that regression.
//
//  Pattern terminator `[\s;,<=)]` anchors on the close of the type name
//  (`Biquad;`, `DelayLine<`, `Lfo =`, `Biquad `, `Lfo)`) so it excludes
//  legitimate tier-3 usage like `persist!(LP_COEFFS: BiquadCoeffs = ...)`
//  and tolerates Monaco snippet placeholders like
//  `persist!(${1:BIQUADS}: [Biquad; ...])`. `)` is in the class so an
//  init-less form like `persist!(LFO: Lfo)` still flags as a tier-2
//  contradiction even though it doesn't tokenize as a valid persist!
//  call. Pattern works in POSIX ERE and NSRegularExpression — no
//  lookaround required.
//
//  Ordering: this test must land AFTER the DocsDriftGuardTests
//  migration-hint dictionary rewrite. The hint values previously
//  contained literal `persist_buf!` substrings; committing this test
//  before that rewrite would fail CI against legitimate in-flight
//  migration text.
//

import Foundation
import Testing

@Suite("PersistMut drift guard")
struct PersistMutDriftGuardTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConjureDSPLogicTests/
            .deletingLastPathComponent()   // repo root
    }

    /// The user-facing teaching surfaces the persist_buf! → persist_mut!
    /// rename touched. Each is read as text (not parsed as Rust/Swift/JS)
    /// so the assertion catches drift in either macro references or example
    /// snippets. `AGENTS.md` covers both repo docs (it's checked in) and
    /// global guides — `CLAUDE.md` is a symlink → `AGENTS.md` so checking
    /// one covers both.
    ///
    /// Not in the list (covered by separate paths):
    ///   - Factory `_rust.cdp/process.rs` — `FactoryRustPresetsCompileTests`
    ///     would fail to compile if a preset still said `persist_buf!`.
    ///   - Library rustdoc + macro_rules — `cargo test` doctest compile +
    ///     `cargo doc -D rustdoc::broken_intra_doc_links` cover both.
    private static let surfaces: [String] = [
        "ConjureDSPExtension/UI/AIPromptHelperView.swift",
        "ConjureDSPTerminal/PTYManager.swift",
        "ConjureDSPExtension/Common/DSPDocumentation.swift",
        "ConjureDSPExtension/Resources/monaco/editor-bridge.js",
        "AGENTS.md",
        // Hypothetical-language-backend design docs reference the
        // Rust persist macros in pattern-detection examples. Originally
        // OOS for the rename (not user teaching surfaces) but added
        // here after two reviewers flagged the copy-paste hazard for
        // future backend authors.
        "docs/adding C support.md",
        "docs/adding-faust-support.md",
    ]

    private static let tier2Pattern =
        #"persist!\(\s*[^)]*?:\s*\[?\s*(Lfo|Biquad|DelayLine)\s*[\s;,<=)]"#

    /// Matches the start of a bare array-repeat literal
    /// `[Biquad::new(); N]` (and `Lfo` / `DelayLine` variants).
    ///
    /// Since `Biquad` / `Lfo` / `DelayLine` lost their `Copy` derive in
    /// the same commit that landed this regex, the bare form fails with
    /// `error[E0277]: T: Copy is not satisfied`. Authors must use
    /// `[const { Biquad::new() }; N]` (inline-const block, exempt from
    /// the Copy bound) — the correct form starts with `const`, not the
    /// type name, so this regex doesn't match it.
    ///
    /// `[Biquad::new()]` (no semicolon — a single-element array) is also
    /// excluded; the regex requires `\(\)\s*;` to anchor specifically on
    /// the array-repeat case.
    private static let copyArrayRepeatPattern =
        #"\[\s*(Lfo|Biquad|DelayLine)(<[^>]+>)?::new\(\)\s*;"#

    private static func read(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func noPersistBufSubstring() throws {
        for surface in Self.surfaces {
            let content = try Self.read(surface)
            #expect(!content.contains("persist_buf"), """
                \(surface) still references the deprecated `persist_buf` macro/struct.
                Replacement: `persist_mut!` / `PersistMut`.
                """)
            #expect(!content.contains("PersistBuf"), """
                \(surface) still references the deprecated `PersistBuf` type.
                Replacement: `PersistMut`.
                """)
        }
    }

    @Test func noTier2Contradictions() throws {
        let regex = try NSRegularExpression(pattern: Self.tier2Pattern)
        for surface in Self.surfaces {
            let content = try Self.read(surface)
            let range = NSRange(content.startIndex..., in: content)
            let matches = regex.matches(in: content, range: range)
            for match in matches {
                let r = Range(match.range, in: content)!
                let hit = String(content[r])
                Issue.record("""
                    \(surface) teaches a tier-2 contradiction: `\(hit)`.
                    Biquad/Lfo/DelayLine mutate via `&mut self` methods — use \
                    `persist_mut!` so the closure body can call them directly \
                    without a get/set round-trip.
                    """)
            }
        }
    }

    /// The terminator-class `[\s;,<=]` must NOT exclude legitimate
    /// tier-3 usage of Copy coefficient structs whose names start with
    /// the DSP-block type names (BiquadCoeffs, hypothetical LfoParams,
    /// DelayLineConfig). A regex regression that dropped the terminator
    /// would false-flag these.
    @Test func tier2PatternExcludesTier3Coefficients() throws {
        let regex = try NSRegularExpression(pattern: Self.tier2Pattern)
        let tier3Legit = [
            "persist!(LP_COEFFS: BiquadCoeffs = BiquadCoeffs::identity());",
            "persist!(HS_COEFFS: BiquadCoeffs = BiquadCoeffs::identity());",
            "persist!(MOD: LfoParams = LfoParams::default());",
            "persist!(CFG: DelayLineConfig = DelayLineConfig::default());",
        ]
        for line in tier3Legit {
            let range = NSRange(line.startIndex..., in: line)
            let match = regex.firstMatch(in: line, range: range)
            #expect(match == nil, "tier-3 line `\(line)` matched the tier-2 regex (false positive)")
        }
    }

    /// Positive-case fixtures for each terminator shape. Asserts the
    /// regex actually catches every real-world syntactic form of the
    /// contradiction. Without this, a future regex regression that
    /// dropped `=` or whitespace from the terminator class could pass
    /// the empty-result check above against only the current strings.
    @Test func tier2PatternMatchesEveryTerminatorShape() throws {
        let regex = try NSRegularExpression(pattern: Self.tier2Pattern)
        let positives = [
            "persist!(BIQUADS: [Biquad; 2] = [Biquad::new(); 2]);",   // ;
            "persist!(DELAY: DelayLine<48000> = DelayLine::new());",  // <
            "persist!(LFO_STATE: Lfo = Lfo::new());",                 // =
            "persist!(LFO: Lfo\n         = Lfo::new());",             // newline (\s)
            "persist!(LFO: Lfo);",                                    // ) — init-less form, invalid Rust but still tier-2 intent
            "persist!(${1:BIQUADS}: [Biquad; MAX_CH] = ...);",        // Monaco placeholder
        ]
        for line in positives {
            let range = NSRange(line.startIndex..., in: line)
            let match = regex.firstMatch(in: line, range: range)
            #expect(match != nil, "tier-2 positive `\(line)` failed to match — terminator class too narrow")
        }
    }

    /// Scan every teaching surface for bare `[Biquad::new(); N]`
    /// array-repeat literals. This is the third pattern class — after
    /// dropping `Copy` from `Biquad` / `Lfo` / `DelayLine`, the bare form
    /// no longer compiles; teaching surfaces must use the inline-const
    /// shape `[const { Biquad::new() }; N]`.
    ///
    /// A reviewer caught 4 occurrences of the broken form in
    /// `DSPDocumentation.swift` and `PTYManager.swift` that the original
    /// rewrite script missed (it only scoped to `.rs`/`.js` paths under
    /// specific directories, missing Swift heredoc strings). This test
    /// prevents that regression.
    @Test func noCopyArrayRepeats() throws {
        let regex = try NSRegularExpression(pattern: Self.copyArrayRepeatPattern)
        for surface in Self.surfaces {
            let content = try Self.read(surface)
            let range = NSRange(content.startIndex..., in: content)
            let matches = regex.matches(in: content, range: range)
            for match in matches {
                let r = Range(match.range, in: content)!
                let hit = String(content[r])
                Issue.record("""
                    \(surface) teaches a bare Copy-array-repeat: `\(hit)…N]`.
                    `Biquad` / `Lfo` / `DelayLine` no longer derive `Copy`, so this
                    fails with `error[E0277]: T: Copy is not satisfied`. Wrap in an
                    inline-const block instead: `[const { TYPE::new() }; N]`.
                    """)
            }
        }
    }

    /// Fixture sweep for the Copy-array-repeat regex. Positive cases
    /// match the broken form across each type. Negative cases exercise
    /// the legitimate alternatives — inline-const blocks, single-element
    /// arrays, and the BiquadCoeffs Copy-value-type form that should
    /// keep working.
    @Test func copyArrayRepeatPatternFixtures() throws {
        let regex = try NSRegularExpression(pattern: Self.copyArrayRepeatPattern)

        let positives = [
            "[Biquad::new(); 2]",
            "[Lfo::new(); MAX_CH]",
            "[DelayLine::new(); 4]",
            "[DelayLine<48000>::new(); 2]",
            "[ Biquad::new() ; 2]",         // tolerates whitespace
        ]
        for line in positives {
            let range = NSRange(line.startIndex..., in: line)
            let match = regex.firstMatch(in: line, range: range)
            #expect(match != nil, "Copy-array-repeat positive `\(line)` failed to match")
        }

        let negatives = [
            "[const { Biquad::new() }; 2]",                  // correct inline-const form
            "[const { [const { Biquad::new() }; 3] }; 2]",   // nested 2D form
            "[BiquadCoeffs::identity(); 4]",                 // Copy value type, still legal
            "[Biquad::new()]",                               // single-element, not array-repeat
        ]
        for line in negatives {
            let range = NSRange(line.startIndex..., in: line)
            let match = regex.firstMatch(in: line, range: range)
            #expect(match == nil, "Copy-array-repeat negative `\(line)` matched (false positive)")
        }
    }
}
