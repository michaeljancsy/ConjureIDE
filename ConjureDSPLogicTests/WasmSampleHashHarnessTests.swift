//
//  WasmSampleHashHarnessTests.swift
//  ConjureDSPLogicTests
//
//  Verifies the harness itself: determinism, sensitivity to input changes,
//  passthrough equivalence. Real-preset golden hashing is precursor 3.
//

import CryptoKit
import Foundation
import Testing

@Suite("WasmSampleHashHarness")
struct WasmSampleHashHarnessTests {

    @Test func defaultInputLengthMatches200MsAt44_1k() {
        let input = WasmSampleHashHarness.defaultInput(sampleRate: 44_100, channels: 2)
        #expect(input.count == 2)
        #expect(input[0].count == 8820)
        #expect(input[0] == input[1])  // mono signal duplicated
    }

    @Test func defaultInputSegmentBoundariesAreSilenceAtStartAndEnd() {
        let input = WasmSampleHashHarness.defaultInput(sampleRate: 44_100, channels: 1)
        let segment = 44_100 / 25  // 40 ms
        for i in 0..<segment {
            #expect(input[0][i] == 0.0)
            #expect(input[0][input[0].count - 1 - i] == 0.0)
        }
    }

    @Test func defaultInputImpulseLocatedAtSecondSegmentStart() {
        let input = WasmSampleHashHarness.defaultInput(sampleRate: 44_100, channels: 1, amplitude: 0.5)
        let segment = 44_100 / 25
        #expect(input[0][segment] == 0.5)
        // Sample after the impulse is silence (decay to zero).
        #expect(input[0][segment + 1] == 0.0)
    }

    @Test func defaultInputIsBitExactReproducible() {
        let a = WasmSampleHashHarness.defaultInput(sampleRate: 48_000, channels: 2)
        let b = WasmSampleHashHarness.defaultInput(sampleRate: 48_000, channels: 2)
        #expect(a == b)
    }

    // MARK: - Passthrough determinism

    @Test func passthroughRenderHashIsDeterministic() throws {
        let input = WasmSampleHashHarness.defaultInput(sampleRate: 44_100, channels: 2)
        let r1 = try WasmSampleHashHarness.render(
            wasmBytes: Data(), input: input, sampleRate: 44_100, blockSize: 256
        )
        let r2 = try WasmSampleHashHarness.render(
            wasmBytes: Data(), input: input, sampleRate: 44_100, blockSize: 256
        )
        #expect(r1.hash == r2.hash)
        #expect(r1.outputBytes == r2.outputBytes)
    }

    @Test func passthroughOutputEqualsInputAfterHash() throws {
        let input = WasmSampleHashHarness.defaultInput(sampleRate: 44_100, channels: 2)
        let result = try WasmSampleHashHarness.render(
            wasmBytes: Data(), input: input, sampleRate: 44_100, blockSize: 256
        )

        // Passthrough kernel writes input → output. The hash should match a
        // direct hash of the input bytes (same byte order).
        var inputBytes = Data(capacity: input.reduce(0) { $0 + $1.count } * MemoryLayout<Float>.size)
        for ch in input {
            ch.withUnsafeBufferPointer { buf in
                inputBytes.append(Data(buffer: buf))
            }
        }
        let expected = SHA256.hash(data: inputBytes).map { String(format: "%02x", $0) }.joined()
        #expect(result.hash == expected)
    }

    // MARK: - Sensitivity

    @Test func differentInputsProduceDifferentHashes() throws {
        let input1 = WasmSampleHashHarness.defaultInput(sampleRate: 44_100, channels: 2, amplitude: 0.5)
        let input2 = WasmSampleHashHarness.defaultInput(sampleRate: 44_100, channels: 2, amplitude: 0.6)
        let r1 = try WasmSampleHashHarness.render(
            wasmBytes: Data(), input: input1, sampleRate: 44_100, blockSize: 256
        )
        let r2 = try WasmSampleHashHarness.render(
            wasmBytes: Data(), input: input2, sampleRate: 44_100, blockSize: 256
        )
        #expect(r1.hash != r2.hash)
    }

    @Test func differentSampleRatesProduceDifferentHashes() throws {
        // Same generator, different SR → different sine phase increments
        // and different total frame counts → different hashes.
        let in44 = WasmSampleHashHarness.defaultInput(sampleRate: 44_100, channels: 2)
        let in48 = WasmSampleHashHarness.defaultInput(sampleRate: 48_000, channels: 2)
        let r44 = try WasmSampleHashHarness.render(
            wasmBytes: Data(), input: in44, sampleRate: 44_100, blockSize: 256
        )
        let r48 = try WasmSampleHashHarness.render(
            wasmBytes: Data(), input: in48, sampleRate: 48_000, blockSize: 256
        )
        #expect(r44.hash != r48.hash)
    }

    @Test func wasmLoadFailureSurfacesError() {
        let input = WasmSampleHashHarness.defaultInput(sampleRate: 44_100, channels: 2)
        // Garbage bytes — load_wasm should reject.
        let junk = Data(repeating: 0xFF, count: 16)
        #expect(throws: WasmSampleHashHarness.Error.self) {
            _ = try WasmSampleHashHarness.render(
                wasmBytes: junk, input: input, sampleRate: 44_100, blockSize: 256
            )
        }
    }
}
