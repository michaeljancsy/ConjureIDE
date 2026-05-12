//
//  PresetGoldenHashTests.swift
//  ConjureDSPLogicTests
//
//  Migration-verification gate for the Rust-script modernization plan.
//  See plans/an-ai-had-this-starry-moler.md.
//
//  Pre-migration: capture goldens (one-time). Post-migration: every
//  preset's hash must still match (or be within ULP tolerance — see the
//  step-5 verification logic).
//
//  These tests compile all 54 factory Rust presets via the bundled rustc
//  (~100s end to end), so they're gated behind `RUN_GOLDEN_HASH_TESTS=1`.
//  To run:
//
//    RUN_GOLDEN_HASH_TESTS=1 xcodebuild test \
//      -only-testing:ConjureDSPLogicTests/PresetGoldenHashTests
//
//  To regenerate the JSON on disk (after a deliberate change), set
//  `WRITE_GOLDEN_HASHES=1` too.
//

import Foundation
import Testing

@Suite("PresetGoldenHashTests")
struct PresetGoldenHashTests {

    private static let sampleRate: Double = 44_100
    private static let blockSize: Int = 256
    private static let channels: Int = 2

    private static var goldensFileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("preset-golden-hashes.json")
    }

    /// Schema of `preset-golden-hashes.json`. Versioned so future
    /// changes (e.g., new fields, different default input) can be
    /// detected and handled explicitly.
    struct Goldens: Codable {
        let version: Int
        let sampleRate: Double
        let blockSize: Int
        let channels: Int
        let presets: [String: String]   // bundleName → SHA256 hex
        let skipped: [String: String]   // bundleName → reason (NAM, etc.)
    }

    @Test
    func goldenHashesMatch() throws {
        guard ProcessInfo.processInfo.environment["RUN_GOLDEN_HASH_TESTS"] == "1" else {
            // Default-off: 54 rustc compiles ≈ 100s, way too slow for the
            // standard logic-test run (~6s). Opt in via env var when
            // working on the modernization plan or refactoring kernel.rs.
            return
        }

        let presets = try PresetWasmCompiler.discoverFactoryRustPresets()
        #expect(presets.count >= 50, "expected ≥50 factory Rust presets, found \(presets.count)")

        let input = WasmSampleHashHarness.defaultInput(
            sampleRate: Self.sampleRate, channels: Self.channels
        )

        var observed: [String: String] = [:]
        var skipped: [String: String] = [:]

        for (name, processRs) in presets {
            let wasm: Data
            do {
                wasm = try PresetWasmCompiler.compile(sourceFile: processRs)
            } catch {
                Issue.record("compile failed for \(name): \(error)")
                continue
            }

            // Probe the module for required NAM slots before rendering. We
            // can't fulfill them in-process (model bytes live on disk in
            // App Support, populated by the running app), so skip those
            // presets and record the reason in the goldens.
            if let reason = probeNamRequirement(wasmBytes: wasm) {
                skipped[name] = reason
                continue
            }

            do {
                let result = try WasmSampleHashHarness.render(
                    wasmBytes: wasm,
                    input: input,
                    sampleRate: Self.sampleRate,
                    blockSize: Self.blockSize
                )
                observed[name] = result.hash
            } catch {
                Issue.record("render failed for \(name): \(error)")
            }
        }

        if ProcessInfo.processInfo.environment["WRITE_GOLDEN_HASHES"] == "1" {
            let goldens = Goldens(
                version: 1,
                sampleRate: Self.sampleRate,
                blockSize: Self.blockSize,
                channels: Self.channels,
                presets: observed,
                skipped: skipped
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(goldens)
            try data.write(to: Self.goldensFileURL)
            // Don't fail when writing — the user explicitly asked for
            // regeneration.
            return
        }

        // Verify mode: every observed hash must match the checked-in golden.
        let goldensData = try Data(contentsOf: Self.goldensFileURL)
        let goldens = try JSONDecoder().decode(Goldens.self, from: goldensData)

        for (name, hash) in observed {
            if let expected = goldens.presets[name] {
                #expect(
                    hash == expected,
                    "audio output changed for \(name): \(expected) → \(hash)"
                )
            } else {
                Issue.record("new preset not in goldens: \(name)")
            }
        }
        for name in goldens.presets.keys where observed[name] == nil && skipped[name] == nil {
            Issue.record("preset in goldens but not observed: \(name)")
        }
    }

    /// Load the module into a throwaway kernel just long enough to query
    /// `dsp_kernel_nam_path_count`. Returns a non-nil reason if the module
    /// needs NAM data we can't supply, otherwise nil.
    private func probeNamRequirement(wasmBytes: Data) -> String? {
        guard let kernel = dsp_kernel_create() else { return nil }
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_set_licensed(kernel, true)
        dsp_kernel_initialize(kernel, Int32(Self.channels), Int32(Self.channels), Self.sampleRate)
        defer { dsp_kernel_deinitialize(kernel) }
        dsp_kernel_set_max_frames(kernel, UInt32(Self.blockSize))

        let loaded = wasmBytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return dsp_kernel_load_wasm(kernel, base, UInt32(wasmBytes.count))
        }
        guard loaded else { return nil }

        let count = dsp_kernel_nam_path_count(kernel)
        return count > 0 ? "requires \(count) NAM model(s)" : nil
    }
}
