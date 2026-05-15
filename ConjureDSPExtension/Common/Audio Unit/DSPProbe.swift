//
//  DSPProbe.swift
//  ConjureDSPExtension
//
//  Offline DSP test runner: synthesize a known input signal, drive it through
//  the loaded backend via dsp_kernel_process, return time-domain stats.
//
//  This file is intentionally AU-free so the logic tests can drive it
//  directly against a bare kernel (no AU instantiation, no host app launch).
//  AU coordination — reading SR/channels, muting via begin/endPresetTransition,
//  reloading the source post-probe — lives in the +MCP.swift handler.
//

import Accelerate
import Foundation

enum DSPProbe {

    enum Signal: Equatable, Sendable {
        case sine(freqHz: Double)
        case impulse
        case silence

        var name: String {
            switch self {
            case .sine: return "sine"
            case .impulse: return "impulse"
            case .silence: return "silence"
            }
        }
    }

    struct Stats: Sendable {
        let rms: Float
        let peak: Float    // |max sample|
        let dc: Float      // mean
        let hasNaN: Bool
        let hasInf: Bool
    }

    struct Result: Sendable {
        let signal: Signal
        let sampleRate: Double
        let channelCount: Int
        let frames: Int
        let blockSize: Int
        let inStats: Stats
        let outStats: Stats
        /// Ratio of the output's dominant spectral peak to the input's,
        /// computed only for sine probes. A value near 1.0 means the
        /// preset preserves pitch (the only correct answer at unity /
        /// identity settings); 2.0 means an octave up; 0.5 means an
        /// octave down; nil means the input was too short for the FFT,
        /// the output was effectively silent, or the input wasn't sine.
        let pitchShiftRatio: Float?
        /// Whether the kernel's declick swap envelope reached IDLE before
        /// the measured render (see `settleSwapEnvelope`). `false` means a
        /// fade was still in flight and `inStats` / `outStats` may be
        /// gain-shaped — the probe should be treated as inconclusive.
        let swapSettled: Bool
    }

    // MARK: - Signal generation

    /// Generate `frames` samples of `signal` into per-channel Float buffers.
    /// All channels receive identical content (mono test signal duplicated).
    static func generate(
        signal: Signal,
        sampleRate: Double,
        frames: Int,
        channels: Int,
        amplitude: Double
    ) -> [[Float]] {
        precondition(frames >= 0)
        precondition(channels >= 1)

        var monoSamples = [Float](repeating: 0, count: frames)
        switch signal {
        case .sine(let freqHz):
            // Double-precision phase accumulator + modulo-2π wrap so long
            // durations don't accumulate float drift.
            let twoPi = 2.0 * Double.pi
            let phaseInc = twoPi * freqHz / sampleRate
            var phase = 0.0
            for i in 0..<frames {
                monoSamples[i] = Float(sin(phase) * amplitude)
                phase += phaseInc
                if phase >= twoPi { phase -= twoPi }
            }
        case .impulse:
            if frames > 0 {
                monoSamples[0] = Float(amplitude)
            }
        case .silence:
            break
        }

        return Array(repeating: monoSamples, count: channels)
    }

    // MARK: - Stats

    /// Time-domain stats over a multi-channel buffer.
    /// Peak is max |x| in any channel; rms and dc are means across the full population.
    static func computeStats(_ buffers: [[Float]]) -> Stats {
        var sumSq: Double = 0
        var sum: Double = 0
        var peak: Float = 0
        var hasNaN = false
        var hasInf = false
        var totalSamples: Int = 0

        for channel in buffers {
            for x in channel {
                if x.isNaN {
                    hasNaN = true
                    continue
                }
                if x.isInfinite {
                    hasInf = true
                    continue
                }
                let dx = Double(x)
                sumSq += dx * dx
                sum += dx
                let mag = abs(x)
                if mag > peak { peak = mag }
                totalSamples += 1
            }
        }

        let rms: Float
        let dc: Float
        if totalSamples > 0 {
            rms = Float((sumSq / Double(totalSamples)).squareRoot())
            dc = Float(sum / Double(totalSamples))
        } else {
            rms = 0
            dc = 0
        }
        return Stats(rms: rms, peak: peak, dc: dc, hasNaN: hasNaN, hasInf: hasInf)
    }

    // MARK: - Offline render

    /// Drive `input` through `kernel` block-by-block and return the output.
    /// Buffers are `[channel][frame]`. Same `dsp_kernel_process` FFI the audio
    /// thread uses → same backend, same state mutations. Caller is responsible
    /// for muting live audio and restoring kernel state afterward.
    static func renderOffline(
        kernel: OpaquePointer,
        input: [[Float]],
        blockSize: Int
    ) -> [[Float]] {
        precondition(blockSize > 0)
        let channelCount = input.count
        guard channelCount > 0 else { return [] }
        let frames = input[0].count

        // Allocate per-channel scratch (one Float[blockSize] per channel) and
        // the output mirror. Using explicit allocation gives us stable
        // base-address pointers without nested withUnsafeMutableBufferPointer.
        let inStorage = (0..<channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: blockSize) }
        let outStorage = (0..<channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: blockSize) }
        defer {
            for p in inStorage { p.deallocate() }
            for p in outStorage { p.deallocate() }
        }
        var inPtrs: [UnsafePointer<Float>?] = inStorage.map { UnsafePointer($0) }
        var outPtrs: [UnsafeMutablePointer<Float>?] = outStorage.map { Optional($0) }

        var output: [[Float]] = Array(
            repeating: [Float](repeating: 0, count: frames),
            count: channelCount
        )

        var offset = 0
        while offset < frames {
            let n = min(blockSize, frames - offset)

            for ch in 0..<channelCount {
                input[ch].withUnsafeBufferPointer { src in
                    if let base = src.baseAddress {
                        inStorage[ch].update(from: base.advanced(by: offset), count: n)
                    }
                }
                if n < blockSize {
                    inStorage[ch].advanced(by: n).update(repeating: 0, count: blockSize - n)
                }
                outStorage[ch].update(repeating: 0, count: blockSize)
            }

            inPtrs.withUnsafeBufferPointer { inPP in
                outPtrs.withUnsafeBufferPointer { outPP in
                    dsp_kernel_process(
                        kernel,
                        inPP.baseAddress,
                        outPP.baseAddress,
                        UInt32(channelCount),
                        UInt32(n)
                    )
                }
            }

            for ch in 0..<channelCount {
                output[ch].withUnsafeMutableBufferPointer { dst in
                    if let base = dst.baseAddress {
                        base.advanced(by: offset).update(from: outStorage[ch], count: n)
                    }
                }
            }

            offset += n
        }

        return output
    }

    // MARK: - Swap-envelope settling

    /// `dsp_kernel_swap_phase` value for the IDLE state — no fade in flight.
    private static let swapPhaseIdle: UInt8 = 0

    /// Feed silent blocks through `kernel` until its declick swap envelope
    /// reports IDLE, so a following measured render is not gain-shaped by a
    /// fade left in flight by a preceding script load. `save_preset` /
    /// `compile_and_run` stage a fresh backend, and the *next*
    /// `dsp_kernel_process` call turns that into a FADE_OUT → swap → FADE_IN;
    /// without this drain the probe's own render would eat that ~30 ms fade.
    ///
    /// At least one block is always processed, so a backend staged but not
    /// yet consumed (phase still IDLE) is forced into its FADE_OUT here
    /// rather than during the measured render. Returns `true` if the kernel
    /// reached IDLE within a generous sample budget, `false` if it was still
    /// mid-transition when the budget ran out (a held `transition_depth`
    /// does this) — the caller should then treat the probe as inconclusive.
    ///
    /// Mirrors the drain `WasmSampleHashHarness.render` performs before
    /// hashing; that harness calls straight into this function.
    @discardableResult
    static func settleSwapEnvelope(
        kernel: OpaquePointer,
        channels: Int,
        blockSize: Int,
        sampleRate: Double
    ) -> Bool {
        precondition(blockSize > 0)
        precondition(channels >= 1)

        let silentBlock = Array(
            repeating: [Float](repeating: 0, count: blockSize),
            count: channels
        )
        // FADE_OUT + FADE_IN are SWAP_FADE_MS each; 150 ms covers both plus
        // block-boundary slack and the swap itself at any sample rate. The
        // loop exits the instant the kernel reports IDLE — the budget is
        // only a backstop against a transition that never closes.
        let budget = max(blockSize, Int((0.15 * sampleRate).rounded()))
        var processed = 0
        repeat {
            _ = renderOffline(kernel: kernel, input: silentBlock, blockSize: blockSize)
            processed += blockSize
            if dsp_kernel_swap_phase(kernel) == swapPhaseIdle { return true }
        } while processed < budget
        return false
    }

    // MARK: - Spectral peak

    /// FFT size for the dominant-frequency detector. 4096 gives ~11.7 Hz
    /// resolution at 48 kHz, which is more than enough to distinguish
    /// the bins that pitch-shift detection cares about (octave, fifth,
    /// fourth, semitone). Quadratic interpolation around the peak refines
    /// to sub-bin precision so that a perfect identity pass reports
    /// ratio ≈ 1.000, not the nearest-bin rounding.
    static let pitchFFTSize = 4096

    /// Find the dominant spectral bin in `samples` and return its
    /// frequency in Hz. Returns nil when the signal is too short
    /// (< pitchFFTSize), effectively silent, or contains non-finite values.
    ///
    /// Uses the *tail* of the input, not the head: stateful presets
    /// (delays, granular, reverbs) typically have zero pre-roll for the
    /// first cycle; sampling from the end of the buffer maximizes the
    /// probability of catching steady-state output.
    static func dominantFrequency(_ samples: [Float], sampleRate: Double) -> Double? {
        let n = pitchFFTSize
        guard samples.count >= n else { return nil }
        let halfN = n / 2
        let log2n = vDSP_Length(log2(Float(n)).rounded())

        // Take the last n samples. Bail if the segment is silent or
        // contains NaN/Inf — both produce meaningless FFT output.
        var segment = Array(samples.suffix(n))
        var peak: Float = 0
        for x in segment {
            if !x.isFinite { return nil }
            let m = abs(x); if m > peak { peak = m }
        }
        guard peak > 1e-6 else { return nil }

        // Hann window in place.
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(segment, 1, window, 1, &segment, 1, vDSP_Length(n))

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)

        segment.withUnsafeBufferPointer { segPtr in
            segPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                realp.withUnsafeMutableBufferPointer { rBuf in
                    imagp.withUnsafeMutableBufferPointer { iBuf in
                        var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfN))
                    }
                }
            }
        }

        // Argmax over bins 1..halfN-1 (skip DC at bin 0; skip the
        // Nyquist sentinel which vDSP packs into imagp[0]).
        var bestBin = 1
        var bestMag: Float = mags[1]
        for k in 2..<halfN {
            if mags[k] > bestMag { bestMag = mags[k]; bestBin = k }
        }

        // Parabolic interpolation for sub-bin precision: fit a parabola
        // through (bestBin-1, bestBin, bestBin+1) and find its vertex.
        // This is the standard FFT-peak refinement; for a windowed sine
        // it gets us within ~0.01 bins of the true frequency.
        let leftBin = max(1, bestBin - 1)
        let rightBin = min(halfN - 1, bestBin + 1)
        let y0 = Double(mags[leftBin])
        let y1 = Double(mags[bestBin])
        let y2 = Double(mags[rightBin])
        let denom = y0 - 2 * y1 + y2
        let binOffset = abs(denom) > 1e-12 ? 0.5 * (y0 - y2) / denom : 0.0
        let refinedBin = Double(bestBin) + binOffset
        return refinedBin * sampleRate / Double(n)
    }

    /// Pitch-shift ratio: output's dominant frequency / input's. Returns
    /// nil for non-sine signals or when either FFT can't resolve a peak.
    /// Channel 0 only — most presets that pitch-shift do so identically
    /// across channels, and a single-channel measurement is sufficient
    /// to flag the bug.
    static func computePitchShiftRatio(
        signal: Signal,
        input: [[Float]],
        output: [[Float]],
        sampleRate: Double
    ) -> Float? {
        guard case .sine = signal else { return nil }
        guard !input.isEmpty, !output.isEmpty else { return nil }
        guard let inFreq = dominantFrequency(input[0], sampleRate: sampleRate),
              let outFreq = dominantFrequency(output[0], sampleRate: sampleRate),
              inFreq > 1.0 else { return nil }
        return Float(outFreq / inFreq)
    }

    // MARK: - End-to-end

    /// Generate test signal, render through `kernel`, return stats.
    /// AU coordination (mute, post-probe reload) is the caller's job.
    static func run(
        kernel: OpaquePointer,
        signal: Signal,
        sampleRate: Double,
        channels: Int,
        blockSize: Int,
        durationMs: Int,
        amplitude: Double
    ) -> Result {
        let frames = max(0, Int((Double(durationMs) / 1000.0 * sampleRate).rounded()))
        let input = generate(
            signal: signal,
            sampleRate: sampleRate,
            frames: frames,
            channels: channels,
            amplitude: amplitude
        )
        // Drain any declick swap envelope to IDLE before the measured render,
        // so a fade left in flight by a preceding script load can't
        // gain-shape the probe signal (see settleSwapEnvelope).
        let swapSettled = settleSwapEnvelope(
            kernel: kernel,
            channels: channels,
            blockSize: blockSize,
            sampleRate: sampleRate
        )
        let output = renderOffline(kernel: kernel, input: input, blockSize: blockSize)
        let pitchRatio = computePitchShiftRatio(
            signal: signal,
            input: input,
            output: output,
            sampleRate: sampleRate
        )
        return Result(
            signal: signal,
            sampleRate: sampleRate,
            channelCount: channels,
            frames: frames,
            blockSize: blockSize,
            inStats: computeStats(input),
            outStats: computeStats(output),
            pitchShiftRatio: pitchRatio,
            swapSettled: swapSettled
        )
    }
}
