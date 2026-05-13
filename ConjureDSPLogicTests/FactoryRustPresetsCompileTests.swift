//
//  FactoryRustPresetsCompileTests.swift
//  ConjureDSPLogicTests
//
//  Asserts every factory `_rust.cdp/process.rs` still compiles cleanly
//  after a sweeping library/macro change. Catches per-preset breakage
//  from a mechanical rewrite that the manual "open one preset and hit
//  Run" check would miss (44 presets × 0 manual clicks).
//
//  Slow: every preset is a wasm32-wasip1 rustc invocation. Gated behind
//  `RUN_FACTORY_COMPILE_TESTS=1` so the default ConjureDSPLogicTests
//  run stays in the ~6 s tier. Set the env var when landing a
//  cross-cutting library change (e.g., macro rename, kernel.rs API
//  change). Mirrors the gate used by PresetGoldenHashTests.
//
//    RUN_FACTORY_COMPILE_TESTS=1 xcodebuild test \
//      -only-testing:ConjureDSPLogicTests/FactoryRustPresetsCompileTests
//

import Foundation
import Testing

@Suite("FactoryRustPresetsCompileTests")
struct FactoryRustPresetsCompileTests {

    @Test
    func everyFactoryPresetCompiles() throws {
        guard ProcessInfo.processInfo.environment["RUN_FACTORY_COMPILE_TESTS"] == "1" else {
            // Default-off: ~44 rustc compiles ≈ 80–100 s, too slow for
            // the standard logic-test run. Opt in via env var when
            // landing a cross-cutting library or macro change.
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
