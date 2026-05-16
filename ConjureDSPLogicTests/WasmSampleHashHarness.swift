//
//  WasmSampleHashHarness.swift
//  ConjureDSPLogicTests
//
//  Sample-level audio verification: load a WASM preset, render against a
//  fixed test signal, hash the raw output bytes. Used by the Rust-script
//  modernization plan as the pre-/post-migration equivalence gate — see
//  plans/an-ai-had-this-starry-moler.md.
//
//  RMS-equal outputs can differ sample-by-sample, exactly the failure
//  mode that delay-line indexing or off-by-one buffer bugs produce. A
//  SHA256 over the rendered bytes catches those without needing per-test
//  oracles.
//

import CryptoKit
import Foundation

enum WasmSampleHashHarness {

    struct Result {
        let hash: String          // SHA256 hex of `outputBytes`
        let output: [[Float]]     // [channel][frame]
        let outputBytes: Data     // raw f32 LE, channels concatenated
    }

    enum Error: Swift.Error {
        case kernelCreateFailed
        case wasmLoadFailed(String?)
        case namInjectFailed(slot: UInt32)
    }

    /// Default test input — 200 ms of mixed signals, segmented at 40 ms each
    /// to exercise common DSP failure modes inside a short render:
    ///
    ///   0–40 ms : silence (warmup tail, also catches NaN/Inf on idle)
    ///   40–80 ms : a unit impulse followed by silence (transient response)
    ///   80–120 ms : 1 kHz sine (steady-state tone)
    ///   120–160 ms : deterministic white noise (broadband stimulus)
    ///   160–200 ms : silence (catches lingering feedback / unresolved state)
    ///
    /// The frame count is always a multiple of 40 ms, so 44.1 kHz → 8820 frames
    /// and 48 kHz → 9600 frames render cleanly.
    static func defaultInput(
        sampleRate: Double,
        channels: Int,
        amplitude: Float = 0.5
    ) -> [[Float]] {
        precondition(channels >= 1)
        precondition(sampleRate > 0)

        let segmentFrames = Int((sampleRate * 0.040).rounded())
        let totalFrames = segmentFrames * 5
        var mono = [Float](repeating: 0, count: totalFrames)

        // Segment 2: impulse at start.
        mono[segmentFrames] = amplitude

        // Segment 3: 1 kHz sine with modulo-2π phase accumulator.
        let twoPi = 2.0 * Double.pi
        let phaseInc = twoPi * 1000.0 / sampleRate
        var phase = 0.0
        for i in 0..<segmentFrames {
            mono[2 * segmentFrames + i] = Float(sin(phase) * Double(amplitude))
            phase += phaseInc
            if phase >= twoPi { phase -= twoPi }
        }

        // Segment 4: seeded LCG noise → reproducible across runs and machines.
        var seed: UInt64 = 0x1234_5678_9ABC_DEF0
        for i in 0..<segmentFrames {
            seed = 6_364_136_223_846_793_005 &* seed &+ 1_442_695_040_888_963_407
            let u32 = UInt32(truncatingIfNeeded: seed >> 32)
            let signed = Int32(bitPattern: u32)
            let normalized = Float(signed) / Float(Int32.max)
            mono[3 * segmentFrames + i] = normalized * amplitude
        }

        // Segments 1 and 5: silence (left at 0).
        return Array(repeating: mono, count: channels)
    }

    /// Render `input` through a fresh kernel with `wasmBytes` loaded.
    /// Pass `Data()` to render with a bare passthrough kernel.
    ///
    /// The harness drives the kernel through any FADE_OUT → FADE_IN swap
    /// envelope to IDLE before starting the hashable render, so the hash
    /// reflects pure backend output (no swap-fade attenuation).
    static func render(
        wasmBytes: Data,
        input: [[Float]],
        sampleRate: Double,
        blockSize: Int = 256,
        params: [(address: UInt64, value: Float)] = [],
        namSlots: [(slot: UInt32, data: Data)] = []
    ) throws -> Result {
        precondition(blockSize > 0)
        precondition(!input.isEmpty)

        guard let kernel = dsp_kernel_create() else {
            throw Error.kernelCreateFailed
        }
        defer { dsp_kernel_destroy(kernel) }

        let channelCount = input.count

        // License so the demo gate never silences the output mid-render.
        dsp_kernel_set_licensed(kernel, true)

        dsp_kernel_initialize(kernel, Int32(channelCount), Int32(channelCount), sampleRate)
        defer { dsp_kernel_deinitialize(kernel) }
        dsp_kernel_set_max_frames(kernel, UInt32(blockSize))

        if !wasmBytes.isEmpty {
            let loaded = wasmBytes.withUnsafeBytes { raw -> Bool in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
                return dsp_kernel_load_wasm(kernel, base, UInt32(wasmBytes.count))
            }
            if !loaded {
                let msg = dsp_kernel_last_error(kernel).map { String(cString: $0) }
                throw Error.wasmLoadFailed(msg)
            }

            for (slot, data) in namSlots {
                let ok = data.withUnsafeBytes { raw -> Bool in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
                    return dsp_kernel_inject_nam_slot(kernel, slot, base, UInt(data.count))
                }
                if !ok { throw Error.namInjectFailed(slot: slot) }
            }
        }

        for (address, value) in params {
            dsp_kernel_set_parameter(kernel, address, value)
        }

        // Drive the swap state machine to IDLE before hashable rendering so
        // the hash reflects pure backend output (no swap-fade attenuation).
        DSPProbe.settleSwapEnvelope(
            kernel: kernel,
            channels: channelCount,
            blockSize: blockSize,
            sampleRate: sampleRate
        )

        let output = DSPProbe.renderOffline(kernel: kernel, input: input, blockSize: blockSize)

        var bytes = Data(capacity: output.reduce(0) { $0 + $1.count } * MemoryLayout<Float>.size)
        for channel in output {
            channel.withUnsafeBufferPointer { buf in
                bytes.append(Data(buffer: buf))
            }
        }

        let digest = SHA256.hash(data: bytes)
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        return Result(hash: hex, output: output, outputBytes: bytes)
    }
}
