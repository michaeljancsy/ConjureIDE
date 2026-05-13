//
//  SpectrogramSmoothingTests.swift
//  ConjureDSPLogicTests
//
//  Pins the symmetric-with-bypass smoother used by the spectrogram column
//  path. α=0.15 one-pole on small steps; snap on |Δ| > 20 dB so note-ons
//  and note-offs render in a single column.
//

import Testing

struct SpectrogramSmoothingTests {

    private static let floorDB: Float = -120.0

    private func runSequence(_ inputs: [Float], initialState: Float = -120.0) -> [Float] {
        var state: [Float] = [initialState]
        var output: [Float] = []
        for x in inputs {
            SpectrogramSmoothing.step(scratch: [x], state: &state)
            output.append(state[0])
        }
        return output
    }

    // MARK: - Hard-step bypass

    @Test func bypassOnLargeUpwardStep() {
        // From floor, a 110 dB rise to −10 is >20 dB, so bypass fires.
        let trace = runSequence([-10])
        #expect(trace == [-10], "Initial onset should bypass from floor; got \(trace)")
    }

    @Test func bypassOnLargeDownwardStep() {
        // Settle at −10, then drop to −90 (80 dB drop): bypass fires.
        let trace = runSequence([-10, -10, -10, -10, -90, -90])
        #expect(trace[4] == -90, "80 dB drop should bypass; got \(trace)")
        #expect(trace[5] == -90, "Subsequent silence stays at floor; got \(trace)")
    }

    @Test func exactlyTwentyDbStepUsesGentle() {
        // 20 dB step is NOT > 20 (strict inequality), so it stays in the
        // gentle one-pole branch.
        let trace = runSequence([-10, -30], initialState: -10)
        // 0.15 * -30 + 0.85 * -10 = -13
        #expect(abs(trace[1] - -13) < 1e-5, "20 dB drop is gentle; got \(trace)")
    }

    // MARK: - Symmetric convergence on stationary wobble

    @Test func stationaryWobbleConvergesTowardMean() {
        // The canonical use case: a sidelobe bin oscillating between two
        // close values from one hop to the next. Symmetric α=0.15 converges
        // toward the mean (-11), oscillating ±0.something around it.
        // (For comparison: an earlier asymmetric attack-snap design would
        // have left ±0.5 swing around -10.5; the symmetric rule is tighter.)
        let trace = runSequence([-10, -12, -10, -12, -10, -12, -10, -12,
                                  -10, -12, -10, -12, -10, -12, -10, -12,
                                  -10, -12, -10, -12], initialState: -11)
        let tail = trace.suffix(6)
        for v in tail {
            #expect(abs(v - -11) < 0.5,
                    "Tail value \(v) should be within 0.5 dB of -11 (the mean); trace=\(trace)")
        }
        // Also confirm the residual peak-to-peak is small enough to land
        // inside one magma index step under visualFloor=−90 (90/256 ≈ 0.35 dB).
        let tailMax = tail.max()!
        let tailMin = tail.min()!
        #expect(tailMax - tailMin < 0.7,
                "Residual swing \(tailMax - tailMin) should be < 0.7 dB; trace=\(trace)")
    }

    @Test func largerStationaryWobbleStillDamps() {
        // 5 dB raw wobble around -12.5. Symmetric α=0.15 should still
        // converge to within ~1.5 dB of the mean.
        let inputs: [Float] = Array(repeating: [Float(-10), Float(-15)], count: 30).flatMap { $0 }
        let trace = runSequence(inputs, initialState: -12)
        let tail = trace.suffix(10)
        for v in tail {
            #expect(abs(v - -12.5) < 1.5,
                    "Tail value \(v) should be within 1.5 dB of -12.5; got tail=\(Array(tail))")
        }
    }

    // MARK: - Small-step release shape

    @Test func smallStepFollowsOnePoleRule() {
        // Settle at -10, step down to -15 (5 dB, gentle branch). State
        // trace: -10, -10, then 0.15*-15 + 0.85*-10 = -10.75,
        // then 0.15*-15 + 0.85*-10.75 = -11.3875.
        let trace = runSequence([-10, -10, -15, -15, -15, -15], initialState: -120)
        // First two: bypass from floor → snap to -10, then no change.
        #expect(abs(trace[0] - -10) < 1e-5)
        #expect(abs(trace[1] - -10) < 1e-5)
        // Third onward: gentle.
        #expect(abs(trace[2] - -10.75) < 1e-5, "got \(trace)")
        #expect(abs(trace[3] - -11.3875) < 1e-5, "got \(trace)")
    }

    // MARK: - Multi-bin coherence

    @Test func independentBinsDoNotInterfere() {
        var state: [Float] = [Self.floorDB, Self.floorDB]

        SpectrogramSmoothing.step(scratch: [-10, -90], state: &state)
        // Both bins: large jump from floor → bypass.
        #expect(state == [-10, -90])

        SpectrogramSmoothing.step(scratch: [-12, -50], state: &state)
        // Bin 0: small step (drop 2), gentle: 0.15*-12 + 0.85*-10 = -10.3.
        // Bin 1: large step (rise 40), bypass: -50.
        #expect(abs(state[0] - -10.3) < 1e-5, "got \(state)")
        #expect(state[1] == -50)
    }
}
