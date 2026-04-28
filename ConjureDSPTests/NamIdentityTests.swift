//
//  NamIdentityTests.swift
//  ConjureDSPTests
//

import Testing
import AVFoundation
import AudioToolbox
import CoreAudioKit

/// Tests the "Approximate Bypass / Identity Function" NAM tone (tone3000 ID: 60092).
/// This tone is a WaveNet standard model trained to approximate a passthrough.
/// The test measures how closely output samples match input samples after warmup,
/// serving as a baseline for NAM integration testing.
@Suite(.serialized)
struct NamIdentityTests {

    // MARK: - Helpers (mirrors ConjureDSPTests)

    private static var componentDescription: AudioComponentDescription {
        get throws {
            guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
                throw TestError("Bundle.main.builtInPlugInsURL is nil")
            }
            let plistURL = plugInsURL
                .appendingPathComponent("ConjureDSPExtension.appex")
                .appendingPathComponent("Contents/Info.plist")
            let data = try Data(contentsOf: plistURL)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let nsExt = plist["NSExtension"] as? [String: Any],
                  let attrs = nsExt["NSExtensionAttributes"] as? [String: Any],
                  let components = attrs["AudioComponents"] as? [[String: Any]],
                  let component = components.first,
                  let type = component["type"] as? String,
                  let subtype = component["subtype"] as? String,
                  let manufacturer = component["manufacturer"] as? String
            else {
                throw TestError("Failed to parse AU identity from embedded extension Info.plist")
            }
            return AudioComponentDescription(
                componentType: fourCharCode(type),
                componentSubType: fourCharCode(subtype),
                componentManufacturer: fourCharCode(manufacturer),
                componentFlags: 0,
                componentFlagsMask: 0
            )
        }
    }

    private struct TestError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        var code: FourCharCode = 0
        for byte in string.utf8 {
            code = code << 8 + FourCharCode(byte)
        }
        return code
    }

    private static func instantiateAU() async throws -> (AVAudioUnit, AUAudioUnit) {
        let desc = try componentDescription
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                let avAudioUnit = try await AVAudioUnit.instantiate(
                    with: desc,
                    options: .loadInProcess
                )
                return (avAudioUnit, avAudioUnit.auAudioUnit)
            } catch {
                if attempt < maxAttempts {
                    try await Task.sleep(for: .milliseconds(500 * attempt))
                    continue
                }
                throw error
            }
        }
        fatalError("unreachable")
    }

    // MARK: - Shared render helper

    private struct NamMetrics {
        let inputRms: Float
        let outputRms: Float
        let rmsError: Float
        let maxError: Float
        /// Error after the output is gain-normalized to match input RMS.
        /// Measures shape / waveform fidelity independently of level.
        let normalizedShapeError: Float
    }

    /// Instantiates a fresh AU, loads the identity NAM, renders a 440 Hz sine
    /// wave at the given `amplitude`, and returns accuracy metrics.
    ///
    /// Each call creates an independent AU instance so tests don't share WaveNet state.
    private func renderIdentityNam(amplitude: Float) async throws -> NamMetrics {
        let (_, au) = try await Self.instantiateAU()

        let namScript = """
            from conjuredsp.nam import load_model

            model = load_model("tone3000://60092/351559")

            def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
                for ch in range(len(inputs)):
                    outputs[ch][:frame_count] = model.process(inputs[ch][:frame_count], ch)
            """
        var state: [String: Any] = au.fullState ?? [:]
        state["pythonScriptSource"] = namScript.data(using: .utf8)!
        au.fullState = state

        let sampleRate: Double = 44100
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)

        let framesPerBatch: UInt32 = 4096
        let totalBatches = 8
        let warmupBatches = 2   // skip 8192 samples for WaveNet receptive-field warmup

        au.maximumFramesToRender = framesPerBatch
        try au.allocateRenderResources()
        let renderBlock = au.renderBlock

        let totalFrames = Int(framesPerBatch) * totalBatches
        let signal: [Float] = (0..<totalFrames).map { i in
            amplitude * Float(sin(2.0 * Double.pi * 440.0 * Double(i) / sampleRate))
        }

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBatch)!
        outputBuffer.frameLength = framesPerBatch

        var allOutputs: [Float] = []
        allOutputs.reserveCapacity(totalFrames)

        for batch in 0..<totalBatches {
            let batchOffset = batch * Int(framesPerBatch)

            let pullInput: AURenderPullInputBlock = { _, _, inFrameCount, _, inputBuf in
                let buf = UnsafeMutableAudioBufferListPointer(inputBuf)
                guard let dst = buf[0].mData?.assumingMemoryBound(to: Float.self) else {
                    return kAudioUnitErr_NoConnection
                }
                for i in 0..<Int(inFrameCount) { dst[i] = signal[batchOffset + i] }
                buf[0].mDataByteSize = inFrameCount * UInt32(MemoryLayout<Float>.size)
                return noErr
            }

            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = Double(batchOffset)
            timestamp.mFlags = .sampleTimeValid

            let status = renderBlock(&flags, &timestamp, framesPerBatch, 0,
                                     outputBuffer.mutableAudioBufferList, pullInput)
            #expect(status == noErr, "Render failed on batch \(batch)")

            let ptr = outputBuffer.floatChannelData![0]
            for i in 0..<Int(framesPerBatch) { allOutputs.append(ptr[i]) }
        }

        au.deallocateRenderResources()

        let warmupSamples = warmupBatches * Int(framesPerBatch)
        let inp = Array(signal[warmupSamples...])
        let out = Array(allOutputs[warmupSamples...])
        let n = inp.count

        var inSumSq: Float = 0
        var outSumSq: Float = 0
        var diffSumSq: Float = 0
        var maxErr: Float = 0
        for i in 0..<n {
            let diff = out[i] - inp[i]
            inSumSq  += inp[i] * inp[i]
            outSumSq += out[i] * out[i]
            diffSumSq += diff * diff
            maxErr = max(maxErr, abs(diff))
        }
        let inputRms  = (inSumSq  / Float(n)).squareRoot()
        let outputRms = (outSumSq / Float(n)).squareRoot()
        let rmsError  = (diffSumSq / Float(n)).squareRoot()

        // Gain-normalize output to input RMS, then measure residual shape error
        let scale = outputRms > 1e-6 ? inputRms / outputRms : 1.0
        var shapeDiffSumSq: Float = 0
        for i in 0..<n {
            let diff = out[i] * scale - inp[i]
            shapeDiffSumSq += diff * diff
        }
        let normalizedShapeError = (shapeDiffSumSq / Float(n)).squareRoot()

        return NamMetrics(inputRms: inputRms, outputRms: outputRms,
                          rmsError: rmsError, maxError: maxErr,
                          normalizedShapeError: normalizedShapeError)
    }

    // MARK: - Identity NAM Accuracy

    /// Full-scale input (0 dBFS, amplitude 1.0).
    ///
    /// The WaveNet standard model scales amplitude down ~9× at this level
    /// (outputRms ≈ 0.08), so rmsError ≈ 0.65. The assertions here only
    /// catch catastrophic failures (silent output, garbage noise).
    @Test func identityNamAtFullScale() async throws {
        let m = try await renderIdentityNam(amplitude: 1.0)

        print("""

            NAM Identity — 0 dBFS input (amplitude 1.0)
            Measured on 24576 samples after 8192-sample warmup:
              Input  RMS:          \(String(format: "%.4f", m.inputRms))
              Output RMS:          \(String(format: "%.4f", m.outputRms))
              RMS error:           \(String(format: "%.6f", m.rmsError))
              Max error:           \(String(format: "%.6f", m.maxError))
              Shape error (norm.): \(String(format: "%.6f", m.normalizedShapeError))
            """)

        #expect(m.outputRms > 0.01,
                "Output RMS \(m.outputRms) is near-zero — model likely failed to load")
        #expect(m.rmsError < 1.2,
                "RMS error \(m.rmsError) is implausibly high — model may be outputting garbage")
    }

    /// Training-level input (≈ −20 dBFS, amplitude 0.1).
    ///
    /// NAM models are typically captured from guitar signals around −20 dBFS.
    /// At this level the model's amplitude response is closer to unity and the
    /// shape error (after gain normalization) is expected to be meaningfully lower
    /// than at full scale.
    @Test func identityNamAtTrainingLevel() async throws {
        let m = try await renderIdentityNam(amplitude: 0.1)

        print("""

            NAM Identity — −20 dBFS input (amplitude 0.1)
            Measured on 24576 samples after 8192-sample warmup:
              Input  RMS:          \(String(format: "%.4f", m.inputRms))
              Output RMS:          \(String(format: "%.4f", m.outputRms))
              RMS error:           \(String(format: "%.6f", m.rmsError))
              Max error:           \(String(format: "%.6f", m.maxError))
              Shape error (norm.): \(String(format: "%.6f", m.normalizedShapeError))
            """)

        #expect(m.outputRms > 0.001,
                "Output RMS \(m.outputRms) is near-zero — model likely failed to load")
        #expect(m.rmsError < 0.12,
                "RMS error \(m.rmsError) exceeds 0.12 — model may not be approximating identity at training level")
    }
}
