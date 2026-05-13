//
//  CircularFloatBufferTests.swift
//  ConjureDSPLogicTests
//
//  Defensive coverage for the audio-capture circular accumulator. The
//  spectrogram's column-stability story rests on `copyPrefix` returning the
//  same sample sequence whether or not a wrap happened mid-window.
//

import Testing

struct CircularFloatBufferTests {

    @Test func emptyBufferCopiesNothing() {
        let buffer = CircularFloatBuffer(capacity: 8)
        var dest = [Float](repeating: -1, count: 8)
        buffer.copyPrefix(8, into: &dest)
        // copyPrefix(min(n, count)) — with count=0 nothing is written, dest stays sentinel.
        #expect(dest == [Float](repeating: -1, count: 8))
    }

    @Test func appendBelowCapacityDoesNotAdvanceHead() {
        var buffer = CircularFloatBuffer(capacity: 8)
        let samples: [Float] = [1, 2, 3, 4]
        buffer.append(contentsOf: samples[0..<4])
        #expect(buffer.count == 4)

        var dest = [Float](repeating: 0, count: 4)
        buffer.copyPrefix(4, into: &dest)
        #expect(dest == [1, 2, 3, 4])
    }

    @Test func appendBeyondCapacityOverwritesOldest() {
        var buffer = CircularFloatBuffer(capacity: 4)
        let samples: [Float] = [1, 2, 3, 4, 5, 6]
        buffer.append(contentsOf: samples[0..<6])
        #expect(buffer.count == 4)

        var dest = [Float](repeating: 0, count: 4)
        buffer.copyPrefix(4, into: &dest)
        // Oldest two (1, 2) overwritten; visible window is [3, 4, 5, 6].
        #expect(dest == [3, 4, 5, 6])
    }

    @Test func copyPrefixHandlesWrapAroundIdentically() {
        // The load-bearing case for the spectrogram: head and tail straddle
        // the storage wrap boundary, and copyPrefix must stitch the two
        // halves back into the original contiguous sequence.
        let capacity = 10
        let total = capacity + 5  // 5-sample overflow forces wrap
        var buffer = CircularFloatBuffer(capacity: capacity)
        let samples: [Float] = (0..<total).map { Float($0) }
        buffer.append(contentsOf: samples[0..<total])

        #expect(buffer.count == capacity)

        var dest = [Float](repeating: -1, count: capacity)
        buffer.copyPrefix(capacity, into: &dest)

        // Expected window is the last `capacity` samples: [5, 6, ..., 14].
        let expected: [Float] = (5..<15).map { Float($0) }
        #expect(dest == expected, "copyPrefix must stitch across the wrap; got \(dest)")
    }

    @Test func dropFirstAdvancesHeadInWrappedState() {
        let capacity = 6
        var buffer = CircularFloatBuffer(capacity: capacity)
        let samples: [Float] = (0..<10).map { Float($0) }
        buffer.append(contentsOf: samples[0..<10])
        // Buffer now holds [4, 5, 6, 7, 8, 9] with head wrapped.

        buffer.dropFirst(3)
        #expect(buffer.count == 3)

        var dest = [Float](repeating: 0, count: 3)
        buffer.copyPrefix(3, into: &dest)
        #expect(dest == [7, 8, 9])
    }

    @Test func sineSequenceRoundTripsThroughWrap() {
        // Mirrors the spectrogram's hop pattern: fill, copy a window, drop a
        // hop, refill from a continuing source. Verifies that successive
        // copyPrefix calls return the bit-exact continuation of the source
        // sequence regardless of where the wrap lands.
        let capacity = 2048
        let hop = 1024
        var buffer = CircularFloatBuffer(capacity: capacity)

        // Synthetic monotonically-increasing signal — any mismatch produces
        // an immediate, easy-to-read difference.
        var source: [Float] = []
        let totalWindows = 6
        let totalSamples = capacity + hop * totalWindows
        source.reserveCapacity(totalSamples)
        for i in 0..<totalSamples {
            source.append(Float(i))
        }

        // Prime the buffer with one full window.
        buffer.append(contentsOf: source[0..<capacity])

        var window = [Float](repeating: 0, count: capacity)
        for w in 0..<totalWindows {
            buffer.copyPrefix(capacity, into: &window)

            let expectedStart = w * hop
            let expected = Array(source[expectedStart..<(expectedStart + capacity)])
            #expect(window == expected,
                    "Window \(w) mismatch — expected first/last = \(expected.first!)/\(expected.last!), got \(window.first!)/\(window.last!)")

            buffer.dropFirst(hop)
            // Refill with the next hop's worth of samples.
            let refillStart = capacity + w * hop
            buffer.append(contentsOf: source[refillStart..<(refillStart + hop)])
        }
    }
}
