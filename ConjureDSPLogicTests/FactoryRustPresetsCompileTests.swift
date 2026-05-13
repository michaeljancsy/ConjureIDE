//
//  FactoryRustPresetsCompileTests.swift
//  ConjureDSPLogicTests
//
//  Asserts every factory `_rust.cdp/process.rs` still compiles cleanly
//  after a sweeping library/macro change. Catches per-preset breakage
//  from a mechanical rewrite that the manual "open one preset and hit
//  Run" check would miss (~50 presets × 0 manual clicks).
//
//  Slow: every preset is a wasm32-wasip1 rustc invocation. Gated behind
//  the `RUN_FACTORY_COMPILE_TESTS` env var so the default
//  ConjureDSPLogicTests run stays in the ~6 s tier. Set it when landing
//  a cross-cutting library change (e.g., macro rename, kernel.rs API
//  change). Mirrors the gate used by PresetGoldenHashTests.
//
//  ⚠ Use the `TEST_RUNNER_` prefix — bare `RUN_FACTORY_COMPILE_TESTS=1
//  xcodebuild test ...` silently no-ops because xcodebuild only
//  forwards env vars to the xctest process when they're prefixed with
//  `TEST_RUNNER_` (the prefix is stripped before the test sees them):
//
//    TEST_RUNNER_RUN_FACTORY_COMPILE_TESTS=1 xcodebuild test \
//      -only-testing:ConjureDSPLogicTests/FactoryRustPresetsCompileTests
//

import Foundation
import Testing

@Suite("FactoryRustPresetsCompileTests")
struct FactoryRustPresetsCompileTests {

    @Test
    func everyFactoryPresetCompiles() throws {
        guard ProcessInfo.processInfo.environment["RUN_FACTORY_COMPILE_TESTS"] == "1" else {
            // Default-off: ~54 rustc compiles ≈ 9 s on a populated build
            // cache (libconjuredsp.rlib is pre-built), too slow for the
            // standard logic-test run. Opt in via env var when landing a
            // cross-cutting library or macro change. Reads
            // `RUN_FACTORY_COMPILE_TESTS` — at the shell, invoke with
            // `TEST_RUNNER_RUN_FACTORY_COMPILE_TESTS=1 xcodebuild …`
            // (xcodebuild strips the `TEST_RUNNER_` prefix before the
            // test process sees the var).
            return
        }

        let presets = try PresetWasmCompiler.discoverFactoryRustPresets()
        #expect(presets.count >= 50, "expected ≥50 factory Rust presets, found \(presets.count)")

        for (name, processRs) in presets {
            do {
                _ = try PresetWasmCompiler.compile(sourceFile: processRs)
            } catch {
                Issue.record("compile failed for \(name): \(error)")
            }
        }
    }
}
