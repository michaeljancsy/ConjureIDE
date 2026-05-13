//
//  DocsDriftGuardTests.swift
//  ConjureDSPLogicTests
//
//  Structural guard against the class of API-drift documentation rot that
//  PRs #305 / #308 surfaced. After the modernization (`process! { ctx => … }`
//  replaces the 5-arg `extern "C" fn process(input, output, ch, frames, sr)`;
//  `persist!` / `persist_mut!` replace `static mut` + `unsafe`), every
//  user-facing teaching surface must teach the new shape — not just the
//  hand-curated docs, but autocomplete snippets, hover docs, default
//  templates, library rustdoc (which the extractor pulls into MCP
//  `get_docs` output), and AI-prompt scaffolds.
//
//  The previous audit pass found 19 stale surfaces by manual grep + review
//  — exactly the workflow that let them accumulate in the first place.
//  This test asserts the cleanup by reading the source files directly and
//  checking they're free of the specific stale patterns. Future regressions
//  of this class fail CI the moment they land.
//
//  Patterns checked are user-named `static mut <IDENT>` (the deprecated
//  state idiom — `persist!`/`persist_mut!` replace it) and the 5-arg
//  `extern "C" fn process(input, …)` signature in its single-line,
//  multi-line-Rust, and JS-snippet-concat forms. The zero-arg
//  `extern "C" fn process()` shape that `process!` emits internally is
//  not matched by these patterns, so the legitimate `Do NOT hand-roll
//  \`extern "C" fn process(...)\`` warning text in DSPDocumentation.swift
//  is safe.
//

import Foundation
import Testing

@Suite("Docs drift guard")
struct DocsDriftGuardTests {

    /// Repo root, derived from this test file's path. Mirrors
    /// `CustomUIAssetParityTests.swift:46` and several others.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConjureDSPLogicTests/
            .deletingLastPathComponent()   // repo root
    }

    /// Substrings that must NOT appear in any user-facing teaching surface.
    /// Each entry is a (pattern, why) pair so a failing assertion explains
    /// the right replacement.
    private static let forbiddenPatterns: [(pattern: String, why: String)] = [
        // User-named `static mut` state — the deprecated idiom.
        // `persist!`/`persist_mut!` replace these. Macro-internal names
        // (INPUT_BUF, OUTPUT_BUF, PARAMS_BUF, TELEMETRY_BUF, NAM_IN, …) are
        // not in this list — they're emitted by setup!()/nam!() etc. and
        // legitimately referenced from inside macros, and we check
        // user-facing teaching files only.
        ("static mut FILTERS",
         "use `persist_mut!(FILTERS: [Biquad; N] = [Biquad::new(); N]);` then `FILTERS.with_mut(|f| { f[c].set_coeffs(coeffs); for i in 0..frames { f[c].process_sample(x) } })`"),
        ("static mut DELAYS",
         "use `persist_mut!(DELAYS: [DelayLine<N>; M] = [DelayLine::new(); M]);` + `DELAYS.with_mut(|d| …)`"),
        ("static mut LFO",
         "use `persist_mut!(LFO: Lfo = Lfo::new());` then `LFO.with_mut(|l| { l.init(sr, rate); for i in 0..frames { let v = l.tick(); … } })`"),
        ("static mut WRITE_POS",
         "use `persist!(WRITE_POS: usize = 0);` + `.get()` / `.set(WRITE_POS.get().wrapping_add(1))`"),
        ("static mut ENVELOPE",
         "use `persist!(ENVELOPE: f64 = 0.0);` + `.get()` / `.set(v)`"),
        ("static mut PREV_OUT",
         "use `persist_mut!(PREV_OUT: [f64; MAX_CH] = [0.0; MAX_CH]);` + `.with_mut(|p| p[c] = …)` — y[n-1] is written every sample inside the feedback loop, that's the tier-3 in-place case (matches preset_lowpass_rust)"),
        ("static mut DELAY_BUF",
         "use `persist_mut!(DELAY_BUF: [[f32; N]; MAX_CH] = …);` + `.with_mut(|b| b[c][i] = v)`"),
        // Hand-rolled biquad state (X1/X2/Y1/Y2 form). Match on the
        // type annotation so we don't flag every `X1` token.
        ("static mut X1: [f64",
         "hand-rolled biquad state — use `persist_mut!(BIQUAD: Biquad = Biquad::new());` then `BIQUAD.with_mut(|b| { b.set_coeffs(coeffs); b.process_sample(x) })`"),
        ("static mut Y1: [f64",
         "hand-rolled biquad state — use `persist_mut!(BIQUAD: Biquad = Biquad::new());` then `BIQUAD.with_mut(|b| { b.set_coeffs(coeffs); b.process_sample(x) })`"),

        // 5-arg `extern "C" fn process(input, …)` signature. Three forms
        // cover the syntactic variants in the codebase:
        //   1. Single-line: `extern "C" fn process(input: *const f32, …)` (rare)
        //   2. Multi-line (Rust source / Swift heredoc / rustdoc):
        //      `extern "C" fn process(\n    input: *const f32,`
        //   3. JS snippet concat (Monaco editor-bridge.js):
        //      `extern "C" fn process(',\n  '\tinput: *const f32,'`
        // The zero-arg `extern "C" fn process()` (current shape) and the
        // `extern "C" fn process(...)` placeholder used in DOCS warnings
        // are NOT matched.
        ("extern \"C\" fn process(input",
         "stale 5-arg signature; replace with `process! { ctx => /* body */ }`"),
        ("extern \"C\" fn process(\n",
         "stale 5-arg multi-line signature; replace with `process! { ctx => /* body */ }`"),
        ("extern \"C\" fn process(',",
         "stale 5-arg JS-snippet signature; rewrite the snippet to emit `process! { ctx => … }`"),
    ]

    /// Read a file relative to the repo root, fail the test if it's
    /// missing (the test surfaces are part of the cleanup contract — a
    /// missing file is itself a regression).
    private static func read(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Assert every forbidden pattern is absent from `content`. Each
    /// failing pattern produces its own assertion failure with the
    /// remediation hint so the test output points at the right fix.
    private static func expectClean(_ content: String, in surfaceName: String) {
        for (pattern, why) in Self.forbiddenPatterns {
            #expect(!content.contains(pattern), """
                \(surfaceName) still teaches stale pattern `\(pattern)`.
                Replacement: \(why)
                See plans/conjuredsp-s-python-and-rust-wiggly-starfish.md for the full sweep.
                """)
        }
    }

    /// (a) Hand-curated documentation in DSPDocumentation.swift — this
    /// is the file MCP `get_docs(topic)` returns. The hand-curated
    /// topic strings ship verbatim to Claude Code and any embedded
    /// agent that hits the MCP server.
    @Test func dspDocumentationSwiftIsClean() throws {
        let content = try Self.read("ConjureDSPExtension/Common/DSPDocumentation.swift")
        Self.expectClean(content, in: "DSPDocumentation.swift")
    }

    /// (b) Library rustdoc — three files whose `///` doc comments on
    /// `pub struct` are extracted by DSPDocumentationExtractor and
    /// appended to MCP `get_docs("filters" | "delays" | "oscillators")`
    /// output. Stale snippets here are LIVE MCP leaks.
    @Test func libraryRustdocIsClean() throws {
        let files = [
            "rust/conjuredsp-rs/src/filters.rs",
            "rust/conjuredsp-rs/src/buffers.rs",
            "rust/conjuredsp-rs/src/osc.rs",
        ]
        for relativePath in files {
            let content = try Self.read(relativePath)
            Self.expectClean(content, in: relativePath)
        }
    }

    /// (c) Default Rust script template, seeded into every new bundle
    /// when the user picks "New Rust preset". Stale here means every
    /// new bundle ships with the wrong entry-point shape from day one.
    @Test func defaultRustTemplateIsClean() throws {
        let template = try Self.read("ConjureDSPExtension/Resources/process.rs")
        Self.expectClean(template, in: "Resources/process.rs")

        // Sanity floor + positive assertion: template must be substantial
        // and must actually use the modern primitives, not just be free
        // of the stale ones.
        #expect(template.count > 100, "Resources/process.rs is suspiciously short (\(template.count) bytes)")
        #expect(template.contains("process!"),
                "Resources/process.rs should teach `process! { ctx => … }` as the entry point")
    }

    /// (d) Embedded duplicate of process.rs in AudioUnitViewController's
    /// `newRustTemplate` string literal. Until Step B (Bundle-load
    /// de-dup) lands, this and (c) must stay in lockstep — this assert
    /// catches drift between them directly. Post-Step-B, this folds
    /// into (c) trivially.
    @Test func audioUnitViewControllerTemplateIsClean() throws {
        let content = try Self.read("ConjureDSPExtension/Common/UI/AudioUnitViewController.swift")
        Self.expectClean(content, in: "AudioUnitViewController.swift")
    }

    /// (e) Monaco autocomplete snippets, hover docs, and the standalone
    /// `setup` snippet in editor-bridge.js. Fires on every keystroke
    /// and every hover in the Rust editor — highest-frequency
    /// teaching surface in the whole product.
    @Test func monacoEditorBridgeIsClean() throws {
        let content = try Self.read("ConjureDSPExtension/Resources/monaco/editor-bridge.js")
        Self.expectClean(content, in: "editor-bridge.js")
    }

    /// (f) AIPromptHelperView's Rust Conventions paragraph. The view
    /// builds prompts users paste into external AI tools (ChatGPT,
    /// Claude.ai, Gemini). Stale bullets here actively mistrain
    /// OUTSIDE agents on the deprecated shape.
    @Test func aiPromptHelperRustConventionsAreClean() throws {
        let content = try Self.read("ConjureDSPExtension/UI/AIPromptHelperView.swift")
        Self.expectClean(content, in: "AIPromptHelperView.swift")
    }

    /// (g) PTYManager.contextContent — written verbatim to
    /// ~/Library/Application Support/ConjureDSP/agent-workspace/{CLAUDE,GEMINI,AGENTS}.md
    /// on every ConjureDSPTerminal launch. The in-plugin Claude / Gemini /
    /// Codex agents read this as project memory before their first
    /// `compile_and_run`. Stale bullets here actively mistrain INSIDE
    /// agents on the deprecated shape (sibling to (f) for outside agents).
    @Test func agentWorkspaceTeachingContextIsClean() throws {
        let content = try Self.read("ConjureDSPTerminal/PTYManager.swift")
        Self.expectClean(content, in: "ConjureDSPTerminal/PTYManager.swift")
    }

    /// (h) Bundled-resource gate for Step B (Bundle-load de-dup of
    /// `newRustTemplate`). After Step B, `AudioUnitViewController`
    /// reads `process.rs` out of the extension's Resources at runtime
    /// instead of inlining the bytes. If the build phase silently
    /// stops shipping `process.rs` into the `.appex` (renamed,
    /// PBXFileSystemSynchronizedRootGroup misconfigured, build script
    /// strips it, etc.), the runtime falls back to a minimal embedded
    /// template and every new bundle gets near-empty source until
    /// somebody notices. The hand-rolled file-content check above
    /// can't catch this — the file would still be clean on disk.
    ///
    /// This test mirrors the precedent in
    /// `ExportTemplateFreshnessTests.findBundledTemplate()` — locate
    /// the built `.appex` relative to the test bundle's
    /// `BUILT_PRODUCTS_DIR` and inspect its Resources directly.
    @Test func processRsIsShippedInBuiltExtensionResources() throws {
        let testBundle = Bundle(for: BundleLocator.self)
        let buildProductsDir = testBundle.bundleURL.deletingLastPathComponent()
        // Two layouts depending on whether the test was invoked via the
        // host app's test action or the extension target's own:
        //   1. xcodebuild test: ConjureDSP.app/Contents/PlugIns/<appex>/Contents/Resources/
        //   2. extension-only:  <appex>/Contents/Resources/
        let candidates: [URL] = [
            buildProductsDir
                .appendingPathComponent("ConjureDSP.app/Contents/PlugIns/ConjureDSPExtension.appex/Contents/Resources/process.rs"),
            buildProductsDir
                .appendingPathComponent("ConjureDSPExtension.appex/Contents/Resources/process.rs"),
        ]
        let resourceURL = try #require(
            candidates.first { FileManager.default.fileExists(atPath: $0.path) },
            """
            process.rs not found in any built `.appex` Resources layout. Tried:
            \(candidates.map { "  \($0.path)" }.joined(separator: "\n"))
            AudioUnitViewController.newRustTemplate's Bundle.url() lookup would
            return nil and silently seed new Rust bundles with the embedded fallback.
            Check Resources/process.rs is still part of the ConjureDSPExtension
            target's PBXFileSystemSynchronizedRootGroup.
            """
        )
        let bundled = try String(contentsOf: resourceURL, encoding: .utf8)
        #expect(bundled.count > 100,
                "Bundled process.rs is only \(bundled.count) bytes — too short to be the real template")
        #expect(bundled.contains("process!"),
                "Bundled process.rs should teach `process! { ctx => … }`")
    }
}

/// Empty class used solely to give `Bundle(for:)` a type anchor in this
/// test bundle. Mirrors `ExportTemplateFreshnessTests.BundleLocator`.
private final class BundleLocator {}
