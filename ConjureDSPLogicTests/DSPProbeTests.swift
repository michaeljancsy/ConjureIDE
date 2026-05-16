//
//  DSPProbeTests.swift
//  ConjureDSPLogicTests
//
//  Pure-logic tests for the DSPProbe helpers (signal generation, stats math)
//  plus an FFI passthrough end-to-end (no AU instantiation, no host launch).
//
//  The full MCP `dsp_probe` handler can't run here — it requires the AU class,
//  which the integration target (ConjureDSPTests) covers. These tests are the
//  fast regression gate for the math + FFI plumbing.
//

import Testing
import Foundation

@Suite("DSPProbeTests")
struct DSPProbeTests {

    // MARK: - Signal generation

    @Test func sineHasCorrectLengthAndRms() {
        let sr: Double = 48_000
        let frames = 1024
        let amp: Double = 0.5
        let buffers = DSPProbe.generate(
            signal: .sine(freqHz: 1000),
            sampleRate: sr,
            frames: frames,
            channels: 1,
            amplitude: amp
        )
        #expect(buffers.count == 1)
        #expect(buffers[0].count == frames)

        // RMS of a full-amplitude sine = amp / √2 ≈ 0.3536.
        let stats = DSPProbe.computeStats(buffers)
        let expectedRms = Float(amp / 2.0.squareRoot())
        #expect(abs(stats.rms - expectedRms) < 0.01)
        #expect(stats.peak <= Float(amp) + 0.001)
        #expect(stats.peak > Float(amp) * 0.99)  // 1 kHz at 48 kHz hits very near peak
        #expect(abs(stats.dc) < 0.01)
        #expect(stats.hasNaN == false)
        #expect(stats.hasInf == false)
    }

    @Test func impulseHasOneNonZeroSample() {
        let buffers = DSPProbe.generate(
            signal: .impulse,
            sampleRate: 48_000,
            frames: 64,
            channels: 1,
            amplitude: 1.0
        )
        #expect(buffers[0][0] == 1.0)
        for i in 1..<64 {
            #expect(buffers[0][i] == 0.0)
        }
    }

    @Test func silenceIsAllZeros() {
        let buffers = DSPProbe.generate(
            signal: .silence,
            sampleRate: 48_000,
            frames: 64,
            channels: 2,
            amplitude: 0.5
        )
        #expect(buffers.count == 2)
        for ch in 0..<2 {
            for s in buffers[ch] {
                #expect(s == 0.0)
            }
        }
    }

    @Test func stereoChannelsMatch() {
        let stereo = DSPProbe.generate(
            signal: .sine(freqHz: 440),
            sampleRate: 48_000,
            frames: 256,
            channels: 2,
            amplitude: 0.5
        )
        #expect(stereo.count == 2)
        #expect(stereo[0] == stereo[1])
    }

    // MARK: - Stats math

    @Test func dcOnlyBufferReportsDc() {
        let stats = DSPProbe.computeStats([[1.0, 1.0, 1.0, 1.0]])
        #expect(stats.rms == 1.0)
        #expect(stats.peak == 1.0)
        #expect(stats.dc == 1.0)
        #expect(stats.hasNaN == false)
        #expect(stats.hasInf == false)
    }

    @Test func bipolarSquareHasZeroDc() {
        let stats = DSPProbe.computeStats([[-1.0, 1.0, -1.0, 1.0]])
        #expect(stats.rms == 1.0)
        #expect(stats.peak == 1.0)
        #expect(stats.dc == 0.0)
    }

    @Test func nanIsDetected() {
        let stats = DSPProbe.computeStats([[0.5, .nan, 0.5]])
        #expect(stats.hasNaN == true)
        #expect(stats.hasInf == false)
    }

    @Test func infIsDetected() {
        let stats = DSPProbe.computeStats([[0.5, .infinity, 0.5]])
        #expect(stats.hasInf == true)
        #expect(stats.hasNaN == false)
    }

    @Test func emptyBufferReturnsZeroStats() {
        let stats = DSPProbe.computeStats([])
        #expect(stats.rms == 0)
        #expect(stats.peak == 0)
        #expect(stats.dc == 0)
        #expect(stats.hasNaN == false)
        #expect(stats.hasInf == false)
    }

    // MARK: - FFI passthrough (end-to-end without AU)

    /// A bare kernel with no script loaded falls back to passthrough — output
    /// equals input. This exercises the full probe pipeline (signal gen +
    /// block-by-block render + stats) against the real FFI surface.
    @Test func passthroughKernelPreservesSineRms() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_initialize(kernel, 1, 1, 48_000)
        defer { dsp_kernel_deinitialize(kernel) }
        dsp_kernel_set_max_frames(kernel, 256)

        let result = DSPProbe.run(
            kernel: kernel,
            signal: .sine(freqHz: 1000),
            sampleRate: 48_000,
            channels: 1,
            blockSize: 256,
            durationMs: 200,
            amplitude: 0.5
        )

        #expect(result.frames == Int(0.2 * 48_000))
        #expect(abs(result.inStats.rms - result.outStats.rms) < 0.001)
        #expect(abs(result.inStats.peak - result.outStats.peak) < 0.001)
        #expect(result.outStats.hasNaN == false)
        #expect(result.outStats.hasInf == false)
    }

    @Test func passthroughKernelImpulsePreservesPeak() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_initialize(kernel, 1, 1, 48_000)
        defer { dsp_kernel_deinitialize(kernel) }
        dsp_kernel_set_max_frames(kernel, 256)

        let result = DSPProbe.run(
            kernel: kernel,
            signal: .impulse,
            sampleRate: 48_000,
            channels: 1,
            blockSize: 256,
            durationMs: 100,
            amplitude: 0.8
        )

        #expect(result.outStats.peak >= Float(0.8) - 0.001)
        #expect(result.outStats.hasNaN == false)
    }

    /// Probe with a block size that doesn't evenly divide the frame count
    /// shouldn't hang or read past buffer ends.
    @Test func probeHandlesPartialLastBlock() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_initialize(kernel, 1, 1, 48_000)
        defer { dsp_kernel_deinitialize(kernel) }
        dsp_kernel_set_max_frames(kernel, 100)

        // 200 ms * 48 kHz = 9600 frames; 9600 / 100 = 96 even blocks.
        // Pick a duration that doesn't divide: 201 ms = 9648 frames, 96 + remainder 48.
        let result = DSPProbe.run(
            kernel: kernel,
            signal: .sine(freqHz: 1000),
            sampleRate: 48_000,
            channels: 1,
            blockSize: 100,
            durationMs: 201,
            amplitude: 0.5
        )
        #expect(result.frames == 9648)
        #expect(abs(result.inStats.rms - result.outStats.rms) < 0.001)
    }

    // MARK: - Swap-envelope contamination regression

    /// Regression: a probe must measure the bare backend, not the kernel's
    /// declick fade. A passthrough kernel is a bit-exact identity; with the
    /// swap envelope armed — the state every `save_preset` leaves behind for
    /// the next probe — the probe must still read a sine back unattenuated
    /// and an impulse back at full peak, and the two signals must agree.
    /// Before `DSPProbe.run` drained the envelope, the armed fade gain-shaped
    /// the head of the render, dragging sine `out_rms` ~2.7% low while
    /// leaving the impulse (whose energy sits on fade gain 1.0) untouched.
    @Test func probeReadsIdentityBitExactThroughArmedSwapEnvelope() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }
        dsp_kernel_initialize(kernel, 1, 1, 48_000)
        defer { dsp_kernel_deinitialize(kernel) }
        dsp_kernel_set_max_frames(kernel, 256)

        // Arm the declick swap envelope without a backend: begin a transition,
        // run one silent block so the kernel moves IDLE → FADE_OUT, then end
        // the transition so the fade is free to complete on later renders.
        func armSwapEnvelope() {
            dsp_kernel_begin_preset_transition(kernel)
            _ = DSPProbe.renderOffline(
                kernel: kernel,
                input: [[Float](repeating: 0, count: 256)],
                blockSize: 256
            )
            dsp_kernel_end_preset_transition(kernel)
        }

        armSwapEnvelope()
        #expect(dsp_kernel_swap_phase(kernel) != DSPProbe.swapPhaseIdle)  // fade armed
        let sine = DSPProbe.run(
            kernel: kernel, signal: .sine(freqHz: 1000), sampleRate: 48_000,
            channels: 1, blockSize: 256, durationMs: 200, amplitude: 0.5
        )
        #expect(sine.swapSettled)
        #expect(abs(sine.inStats.rms - sine.outStats.rms) < 1e-5)
        #expect(abs(sine.inStats.peak - sine.outStats.peak) < 1e-5)

        armSwapEnvelope()
        #expect(dsp_kernel_swap_phase(kernel) != DSPProbe.swapPhaseIdle)
        let impulse = DSPProbe.run(
            kernel: kernel, signal: .impulse, sampleRate: 48_000,
            channels: 1, blockSize: 256, durationMs: 200, amplitude: 0.5
        )
        #expect(impulse.swapSettled)
        #expect(abs(impulse.inStats.rms - impulse.outStats.rms) < 1e-5)
        #expect(abs(impulse.inStats.peak - impulse.outStats.peak) < 1e-5)
    }
}
