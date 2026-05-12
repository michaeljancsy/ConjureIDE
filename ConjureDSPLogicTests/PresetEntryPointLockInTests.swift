//
//  PresetEntryPointLockInTests.swift
//  ConjureDSPLogicTests
//
//  Standing guard against a future factory preset that bypasses the
//  process! macro and goes back to hand-rolling `extern "C" fn process`.
//  Step 7 of plans/an-ai-had-this-starry-moler.md.
//
//  After the modernization plan, every factory Rust preset's process.rs
//  must invoke `process! { ctx => /* body */ }`. The host-side WASM
//  backend (rust/conjure_dsp/src/wasm_backend.rs) expects a zero-arg
//  `process()` export now; a hand-rolled 5-arg signature would fail to
//  load.
//

import Foundation
import Testing

@Suite("PresetEntryPointLockIn")
struct PresetEntryPointLockInTests {

    private static var presetsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()            // ConjureDSPLogicTests/
            .deletingLastPathComponent()            // <repo>/
            .appendingPathComponent("ConjureDSPExtension/Resources/presets")
    }

    /// Every factory Rust preset must use `process! { ctx => … }`. A
    /// preset that still writes `#[no_mangle] pub extern "C" fn process(…)`
    /// (or `#[unsafe(no_mangle)] pub extern "C" fn process(…)`) by hand
    /// would compile but fail to instantiate against the zero-arg host
    /// ABI — caught here at the source level before that runtime failure.
    @Test
    func everyRustPresetUsesProcessMacro() throws {
        let fm = FileManager.default
        let dir = Self.presetsDir
        let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)

        var checked = 0
        for entry in entries where entry.pathExtension == "cdp" {
            let processRs = entry.appendingPathComponent("process.rs")
            if !fm.fileExists(atPath: processRs.path) { continue }
            let source = try String(contentsOf: processRs, encoding: .utf8)
            checked += 1

            let name = entry.deletingPathExtension().lastPathComponent
            #expect(
                source.contains("process! {") || source.contains("process!{"),
                "\(name)/process.rs must use process! { ctx => … } — see step 5 of the modernization plan"
            )
            // Forbid the legacy hand-rolled entry point. Allow ordinary
            // function signatures in helpers (only the literal `fn process(`
            // pattern is banned).
            let banned = [
                "extern \"C\" fn process(",
                "extern \"C\" fn process (",
            ]
            for needle in banned {
                #expect(
                    !source.contains(needle),
                    "\(name)/process.rs still defines a hand-rolled `extern \"C\" fn process(...)` — must use process! macro"
                )
            }
        }
        #expect(checked >= 50, "expected ≥50 factory Rust presets, scanned \(checked)")
    }
}
