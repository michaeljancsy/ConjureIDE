//
//  SpectrogramSmoothing.swift
//  ConjureDSPExtension
//
//  Per-bin asymmetric smoother applied to the spectrogram column rings.
//  Symmetric one-pole on small dB steps, hard-step bypass on |Δ| > 20 dB.
//
//  Extracted from AudioCaptureManager so ConjureDSPLogicTests can compile
//  against the same source the appex uses (no hand-copy drift). The α
//  and bypass-threshold constants are exposed publicly so tests can
//  reference them directly rather than hardcoding values.
//

import Foundation

enum SpectrogramSmoothing {
    /// One-pole release coefficient for the gentle-release branch.
    ///
    /// α=0.15 chosen empirically: the deep-sidelobe cross-term wobble for
    /// an off-bin sine through a Hann window can hit 5–8 dB peak-to-peak
    /// in bins where the positive and negative image responses are
    /// comparable. A one-pole at Nyquist alternation attenuates by
    /// α/(2-α) — α=0.3 gives -15 dB (~1 dB residual on 8 dB input, still
    /// visible); α=0.15 gives -22 dB (~0.5 dB residual, below one magma
    /// index step under visualFloor=-90). Time constant is ~7 columns
    /// ≈ 150 ms at 46 cols/sec — noticeable lag on dynamics but the
    /// 20 dB bypass catches the loud-step cases that matter most.
    static let alpha: Float = 0.15

    /// Step magnitude (dB) above which the smoother bypasses and snaps
    /// directly to the new value. Catches note-ons, note-offs, signal
    /// start-stop, and any other transient larger than legitimate
    /// dynamic variation we want to track.
    static let bypassThresholdDB: Float = 20.0

    /// Apply the symmetric-with-bypass smoother in-place on `state`.
    /// Per-bin rule:
    ///   - `|s − x| > bypassThresholdDB`: `s = x` (snap)
    ///   - otherwise:                     `s = α·x + (1-α)·s` (one-pole)
    ///
    /// Operates in the dB domain. Since dB = 10·log10(power), running
    /// a one-pole on dB values converges to the arithmetic mean of
    /// dB inputs over the smoother's time window — equivalently, the
    /// **geometric** mean of the linear magnitude. For visualization
    /// of a stationary spectrum that's the right answer (perceptually,
    /// equal dB deltas look equal); for energy-correct PSD estimation
    /// of a stationary signal you'd want arithmetic mean in linear
    /// power instead. This smoother is for display, not measurement,
    /// so the dB-domain convergence is the desired behavior.
    ///
    /// A/B verified load-bearing: with this disabled (and CGContext
    /// interpolation correctly pinned via withCGContext), vertical
    /// striping returns across the full spectrum, not just sidelobe
    /// bins. The cross-term wobble in `|X[k]|` for a real Hann-windowed
    /// off-bin sine is genuinely 5–8 dB peak-to-peak in low-magnitude
    /// bins and renders as visible stripes through the magma palette
    /// without smoothing.
    static func step(scratch: [Float], state: inout [Float]) {
        let oneMinusAlpha: Float = 1.0 - alpha
        let n = scratch.count
        // Size mismatch means setupFFT didn't reallocate the EMA arrays
        // alongside the scratch buffers — a real bug if it happens.
        // assertionFailure in debug so a future resize-race surfaces loudly;
        // release falls back to silent no-op so the visualization doesn't
        // crash the AU.
        guard state.count == n else {
            assertionFailure("SpectrogramSmoothing.step size mismatch: scratch=\(n) state=\(state.count)")
            return
        }
        for i in 0..<n {
            let x = scratch[i]
            let s = state[i]
            if abs(s - x) > bypassThresholdDB {
                state[i] = x
            } else {
                state[i] = alpha * x + oneMinusAlpha * s
            }
        }
    }
}
