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
        let output = renderOffline(kernel: kernel, input: input, blockSize: blockSize)
        return Result(
            signal: signal,
            sampleRate: sampleRate,
            channelCount: channels,
            frames: frames,
            blockSize: blockSize,
            inStats: computeStats(input),
            outStats: computeStats(output)
        )
    }
}
