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

    /// Every factory Rust preset must declare its render-block state via
    /// `persist!(…)` or `persist_buf!(…)` — never raw `static mut`. The
    /// raw shape works under edition 2024 only because `static_mut_refs`
    /// fires on `&` / `&mut` creation, not on direct `X = v` writes — but
    /// the moment a new preset reaches for `.as_ptr()` or a `&mut self`
    /// method on a Lfo/Biquad/DelayLine it'll trip the deny lint at
    /// compile time. Catching the regression at the source level is
    /// cheaper than chasing it through cargo errors later.
    ///
    /// Allowance: a small set of complex DSP presets carry
    /// `#![allow(static_mut_refs)]` at file scope as the plan's "Plan B"
    /// fallback. Those files are listed here explicitly so that the
    /// list shrinks as state migration completes; adding a new entry
    /// to the allow-list requires updating this test, which forces a
    /// reviewer to evaluate whether the bypass is justified.
    @Test
    func noFactoryPresetUsesRawStaticMut() throws {
        let fm = FileManager.default
        let dir = Self.presetsDir
        let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)

        // Presets carrying raw `static mut` declarations under the
        // plan's "Plan B" fallback (with or without
        // `#![allow(static_mut_refs)]`). The list shrinks as state
        // migration completes; each removal is a per-preset
        // `persist!()` / `persist_buf!()` PR. New additions require
        // reviewer sign-off — they're an explicit step backward from
        // the modernization goal.
        let bypassAllowList: Set<String> = [
            "preset_acid_sermon_rust", "preset_alien_radio_rust",
            "preset_astronauts_garden_rust",
            "preset_black_hole_vespers_rust", "preset_broken_fax_lullaby_rust",
            "preset_burial_at_sea_rust", "preset_chorus_rust",
            "preset_dying_star_rust",
            "preset_eq3_rust", "preset_flanger_rust",
            "preset_geiger_bells_rust", "preset_ghost_choir_rust",
            "preset_glass_smash_rust", "preset_hailstorm_lullaby_rust",
            "preset_haunted_cathedral_rust", "preset_last_transmission_rust",
            "preset_lookahead_limiter_rust",
            "preset_methane_sea_rust", "preset_mockingbird_at_night_rust",
            "preset_morphine_drip_rust", "preset_mothlight_rust",
            "preset_permafrost_dream_rust", "preset_phaser_rust",
            "preset_plague_doctor_rust",
            "preset_rusted_carousel_rust",
            "preset_sunbaked_cassette_rust",
            "preset_termite_cathedral_rust",
            "preset_tin_can_telephone_rust", "preset_underwater_spy_rust",
            "preset_wah_rust", "preset_whalebone_organ_rust",
            "preset_deesser_rust",
            // Migrated to persist! / persist_buf!:
            //   preset_bitcrush_rust, preset_compressor_rust,
            //   preset_compressor_sidechain_rust, preset_dcblocker_rust,
            //   preset_delay_rust, preset_lowpass_rust, preset_pingpong_rust,
            //   preset_svf_rust, preset_telemetry_smoke, preset_tremolo_rust
            //   (plus the prior wave: preset_limiter_rust, preset_noisegate_rust,
            //   preset_ringmod_rust, preset_whitenoise_rust)
        ]

        for entry in entries where entry.pathExtension == "cdp" {
            let processRs = entry.appendingPathComponent("process.rs")
            if !fm.fileExists(atPath: processRs.path) { continue }
            let source = try String(contentsOf: processRs, encoding: .utf8)
            let name = entry.deletingPathExtension().lastPathComponent

            let hasStaticMut = source.range(
                of: #"\bstatic\s+mut\s+[A-Z_][A-Z0-9_]*\s*:"#,
                options: .regularExpression
            ) != nil
            let hasAllowAttr = source.contains("#![allow(static_mut_refs)]")

            if bypassAllowList.contains(name) {
                #expect(
                    hasAllowAttr,
                    "\(name) is on the bypass allow-list but is missing #![allow(static_mut_refs)] — remove it from the list or restore the attribute"
                )
                continue
            }
            #expect(
                !hasStaticMut,
                "\(name)/process.rs declares raw `static mut` — migrate to persist!() or persist_buf!() per plans/an-ai-had-this-starry-moler.md"
            )
            #expect(
                !hasAllowAttr,
                "\(name)/process.rs has #![allow(static_mut_refs)] but isn't on the bypass allow-list — remove the attribute"
            )
        }
    }
}
