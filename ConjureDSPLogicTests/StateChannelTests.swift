//
//  StateChannelTests.swift
//  ConjureDSPLogicTests
//
//  Pins the FFI contract for the bundle-private STATE channel —
//  UI-writable, audio-readable JSON that lives outside the AU
//  parameter tree and persists via the DAW project.
//
//  Each test exercises the kernel directly via the C FFI in
//  `conjure_dsp.h` (no AU instantiation), so they all run in the
//  fast logic-test target. The functions under test:
//
//    - dsp_kernel_set_state_cap        — install a per-script byte cap
//    - dsp_kernel_state_cap            — query the current cap
//    - dsp_kernel_set_state_json       — install JSON bytes (validates
//                                        + cap-checks, atomic swap)
//    - dsp_kernel_get_state_json       — copy current bytes out
//    - dsp_kernel_state_generation     — counter bumped on every
//                                        successful set
//

import Foundation
import Testing

struct StateChannelTests {

    /// Convenience: set state from `Data`. Returns the FFI bool.
    private static func setStateBytes(_ kernel: OpaquePointer, _ bytes: Data) -> Bool {
        bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return dsp_kernel_set_state_json(kernel, base.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
        }
    }

    /// Convenience: read out the full state buffer.
    private static func readState(_ kernel: OpaquePointer) -> Data {
        let needed = Int(dsp_kernel_get_state_json(kernel, nil, UInt(0)))
        guard needed > 0 else { return Data() }
        var out = Data(count: needed)
        let written = out.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Int(dsp_kernel_get_state_json(kernel, base.assumingMemoryBound(to: UInt8.self), UInt(needed)))
        }
        if written < out.count {
            out = out.prefix(written)
        }
        return out
    }

    // MARK: - Round-trip

    @Test func stateBufferRoundTripsJSON() async throws {
        let kernel = try #require(dsp_kernel_create())
        defer { dsp_kernel_destroy(kernel) }

        let bytes = "{\"slots\":[1,2,3]}".data(using: .utf8)!
        let ok = Self.setStateBytes(kernel, bytes)
        #expect(ok, "well-formed JSON within the cap should install")

        // Query length first (the documented `out=NULL, max_len=0` path).
        let needed = dsp_kernel_get_state_json(kernel, nil, UInt(0))
        #expect(needed == bytes.count,
                "queried length must equal the bytes we wrote (\(bytes.count)); got \(needed)")

        let out = Self.readState(kernel)
        #expect(out == bytes,
                "buffer must round-trip byte-for-byte; got \(String(data: out, encoding: .utf8) ?? "<non-utf8>")")
    }

    // MARK: - Generation counter

    @Test func stateGenerationBumpsOnSetButNotOnGet() async throws {
        let kernel = try #require(dsp_kernel_create())
        defer { dsp_kernel_destroy(kernel) }

        let gen0 = dsp_kernel_state_generation(kernel)

        let ok = Self.setStateBytes(kernel, Data("{\"a\":1}".utf8))
        #expect(ok)
        let gen1 = dsp_kernel_state_generation(kernel)
        #expect(gen1 > gen0, "successful set must advance the generation counter")

        // Pure reads must NOT advance the counter — the audio thread
        // checks gen vs cached-gen to decide whether to re-deserialize,
        // and a getter that bumped gen would force re-parse every block.
        _ = Self.readState(kernel)
        _ = Self.readState(kernel)
        let genAfterReads = dsp_kernel_state_generation(kernel)
        #expect(genAfterReads == gen1,
                "reads must not advance the generation counter; \(gen1) -> \(genAfterReads)")

        // Another successful set advances by exactly one.
        let ok2 = Self.setStateBytes(kernel, Data("{\"a\":2}".utf8))
        #expect(ok2)
        let gen2 = dsp_kernel_state_generation(kernel)
        #expect(gen2 == gen1 + 1, "every accepted set must advance gen by 1; \(gen1) -> \(gen2)")
    }

    // MARK: - JSON validation

    @Test func stateRejectsMalformedJSON() async throws {
        let kernel = try #require(dsp_kernel_create())
        defer { dsp_kernel_destroy(kernel) }

        // Establish a known good buffer first so we can assert the
        // rejection didn't clobber it.
        let initial = Data("{\"keep\":true}".utf8)
        #expect(Self.setStateBytes(kernel, initial))
        let genBefore = dsp_kernel_state_generation(kernel)

        // Garbage bytes (not even close to JSON) — kernel must reject
        // structurally so backends don't blow up on every render.
        let bad = Data("{not valid".utf8)
        let ok = Self.setStateBytes(kernel, bad)
        #expect(!ok, "malformed JSON must be rejected")

        let genAfter = dsp_kernel_state_generation(kernel)
        #expect(genAfter == genBefore,
                "rejected write must NOT advance gen (\(genBefore) -> \(genAfter))")

        let buf = Self.readState(kernel)
        #expect(buf == initial,
                "rejected write must leave the existing buffer untouched")
    }

    // MARK: - Size cap enforcement

    @Test func stateRejectsOversizeWrites() async throws {
        let kernel = try #require(dsp_kernel_create())
        defer { dsp_kernel_destroy(kernel) }

        // Tighten the cap so we can blow past it without allocating
        // anything huge in the test.
        dsp_kernel_set_state_cap(kernel, UInt(100))

        let small = Data("{\"k\":1}".utf8)
        #expect(Self.setStateBytes(kernel, small),
                "small write within the cap should succeed")
        let genBefore = dsp_kernel_state_generation(kernel)

        // Build a payload definitely > 100 bytes. JSON-valid string with
        // a long value field.
        let big = Data(("{\"big\":\"" + String(repeating: "x", count: 200) + "\"}").utf8)
        #expect(big.count > 100)
        let ok = Self.setStateBytes(kernel, big)
        #expect(!ok, "write of \(big.count) bytes against a 100-byte cap must reject")

        let genAfter = dsp_kernel_state_generation(kernel)
        #expect(genAfter == genBefore,
                "over-cap rejection must NOT advance gen")
        #expect(Self.readState(kernel) == small,
                "over-cap rejection must leave existing buffer intact")
    }

    @Test func stateCapPropagatesToWrites() async throws {
        let kernel = try #require(dsp_kernel_create())
        defer { dsp_kernel_destroy(kernel) }

        // Pick a small but non-trivial cap. A 60-byte JSON object fits
        // within a 60-byte cap but not within a 30-byte one.
        let payload = Data("{\"some_key_name\":\"some-value-string-content\"}".utf8)
        #expect(payload.count <= 60 && payload.count > 30,
                "test fixture sized for the two-step cap window")

        // Cap = N (≥ payload size): write succeeds.
        dsp_kernel_set_state_cap(kernel, UInt(60))
        #expect(dsp_kernel_state_cap(kernel) == 60)
        #expect(Self.setStateBytes(kernel, payload),
                "payload (\(payload.count)) must fit within cap=60")

        // Cap = N/2 (< payload size): same payload now rejects, even
        // though it was accepted under the previous cap.
        dsp_kernel_set_state_cap(kernel, UInt(30))
        #expect(dsp_kernel_state_cap(kernel) == 30)
        #expect(!Self.setStateBytes(kernel, payload),
                "payload (\(payload.count)) must reject under cap=30")
    }

    // MARK: - Initial state

    @Test func stateInitialBufferIsEmptyJSON() async throws {
        let kernel = try #require(dsp_kernel_create())
        defer { dsp_kernel_destroy(kernel) }

        // A fresh kernel must start with valid JSON in the buffer so
        // backends that snapshot+deserialize on the very first render
        // never see undefined bytes. The simplest valid JSON value the
        // kernel can ship is `{}`.
        let initial = Self.readState(kernel)
        let str = String(data: initial, encoding: .utf8) ?? "<non-utf8>"
        #expect(str == "{}",
                "fresh kernel must seed state buffer with empty JSON object; got \(str)")
        #expect(dsp_kernel_state_generation(kernel) == 0,
                "fresh kernel state generation must be zero before any set")
    }

    // MARK: - Length-only query path

    @Test func stateGetWithNullBufferReturnsLengthOnly() async throws {
        let kernel = try #require(dsp_kernel_create())
        defer { dsp_kernel_destroy(kernel) }

        let payload = Data("{\"length_test\":42}".utf8)
        #expect(Self.setStateBytes(kernel, payload))

        // The documented `out=NULL, max_len=0` query path returns the
        // length the kernel wants to write without actually writing.
        let needed = Int(dsp_kernel_get_state_json(kernel, nil, UInt(0)))
        #expect(needed == payload.count,
                "null-query must return exact length; got \(needed) vs \(payload.count)")
    }
}
