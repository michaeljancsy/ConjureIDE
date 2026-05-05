//
//  PresetTransitionTests.swift
//  ConjureDSPLogicTests
//
//  FFI-level smoke tests for the preset-transition mute envelope. The
//  audio-correctness assertions live in `cargo test` (kernel.rs); these
//  tests exercise the FFI surface so a missing or mis-wired symbol is
//  caught at the Swift compile/test boundary rather than at AU runtime.
//
//  Asana: 1214132137985530 — preset-switch loud noise not fully eliminated.
//

import Testing

private let SWAP_PHASE_IDLE: UInt8 = 0
private let SWAP_PHASE_FADE_OUT: UInt8 = 1
private let SWAP_PHASE_FADE_IN: UInt8 = 2

@Suite("PresetTransitionTests")
struct PresetTransitionTests {

    @Test func freshKernelSwapPhaseIsIdle() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        #expect(dsp_kernel_swap_phase(kernel) == SWAP_PHASE_IDLE)
    }

    /// `begin_preset_transition` is purely a flag-set; without a render
    /// callback the phase doesn't transition (the audio thread observes
    /// the flag at the top of `process()` and arms the FADE_OUT). Calling
    /// `end` immediately after `begin` should not crash, and phase is
    /// still IDLE because `process()` was never called between them.
    @Test func beginEndIsIdempotentAndCrashSafe() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_begin_preset_transition(kernel)
        dsp_kernel_begin_preset_transition(kernel) // idempotent
        dsp_kernel_end_preset_transition(kernel)
        dsp_kernel_end_preset_transition(kernel) // idempotent
        #expect(dsp_kernel_swap_phase(kernel) == SWAP_PHASE_IDLE)
    }

    /// After begin + at least one process callback, the phase advances to
    /// FADE_OUT (the audio thread observed `transition_active`). After end
    /// + enough callbacks, the phase returns to IDLE via FADE_IN.
    @Test func transitionDrivesPhaseThroughFadeOutAndBack() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_initialize(kernel, 1, 1, 44100)
        dsp_kernel_set_max_frames(kernel, 64)

        // No backend loaded — kernel falls back to passthrough, but the
        // envelope state machine still runs.
        let frames: UInt32 = 64
        var input = [Float](repeating: 0.5, count: Int(frames))
        var output = [Float](repeating: 0.0, count: Int(frames))

        // Begin: arm FADE_OUT on the next callback.
        dsp_kernel_begin_preset_transition(kernel)
        input.withUnsafeMutableBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                var ip: UnsafePointer<Float>? = UnsafePointer(inBuf.baseAddress)
                var op: UnsafeMutablePointer<Float>? = outBuf.baseAddress
                withUnsafePointer(to: &ip) { ipp in
                    withUnsafePointer(to: &op) { opp in
                        dsp_kernel_process(
                            kernel,
                            UnsafeRawPointer(ipp).assumingMemoryBound(to: UnsafePointer<Float>?.self),
                            UnsafeRawPointer(opp).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self),
                            1, frames
                        )
                    }
                }
            }
        }
        #expect(dsp_kernel_swap_phase(kernel) == SWAP_PHASE_FADE_OUT)

        // End + run several callbacks to fully drain FADE_OUT (15 ms ×
        // 44.1 kHz = ~661 samples) + FADE_IN. 32 × 64 = 2048 samples is
        // ~3 fade lengths, plenty.
        dsp_kernel_end_preset_transition(kernel)
        for _ in 0..<32 {
            input.withUnsafeMutableBufferPointer { inBuf in
                output.withUnsafeMutableBufferPointer { outBuf in
                    var ip: UnsafePointer<Float>? = UnsafePointer(inBuf.baseAddress)
                    var op: UnsafeMutablePointer<Float>? = outBuf.baseAddress
                    withUnsafePointer(to: &ip) { ipp in
                        withUnsafePointer(to: &op) { opp in
                            dsp_kernel_process(
                                kernel,
                                UnsafeRawPointer(ipp).assumingMemoryBound(to: UnsafePointer<Float>?.self),
                                UnsafeRawPointer(opp).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self),
                                1, frames
                            )
                        }
                    }
                }
            }
        }
        #expect(dsp_kernel_swap_phase(kernel) == SWAP_PHASE_IDLE)

        dsp_kernel_deinitialize(kernel)
    }
}
