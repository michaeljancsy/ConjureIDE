//
//  SpectrogramSmoothing.swift
//  ConjureDSPLogicTests
//
//  Minimal copy of `applySpectrogramSmoothing` from AudioCaptureManager
//  for unit testing. The AU extension target can't be @testable-imported
//  because it's an appex. Keep the per-bin rule bit-identical to the
//  production source.
//

enum SpectrogramSmoothing {
    /// Symmetric per-bin smoother with a hard-step bypass: α=0.15 one-pole
    /// for small steps, snap on |Δ| > 20 dB.
    static func step(scratch: [Float], state: inout [Float]) {
        let alpha: Float = 0.15
        let oneMinusAlpha: Float = 1.0 - alpha
        let bypassThreshold: Float = 20.0
        let n = scratch.count
        guard state.count == n else { return }
        for i in 0..<n {
            let x = scratch[i]
            let s = state[i]
            if abs(s - x) > bypassThreshold {
                state[i] = x
            } else {
                state[i] = alpha * x + oneMinusAlpha * s
            }
        }
    }
}
