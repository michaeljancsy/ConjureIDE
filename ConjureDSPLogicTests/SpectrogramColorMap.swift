//
//  SpectrogramColorMap.swift
//  ConjureDSPLogicTests
//
//  Minimal copy of SpectrogramColorMap from ConjureDSPExtension for unit testing.
//  The AU extension target can't be @testable-imported because it's an appex.
//
//  Keep the magma anchors, dB→index math, and the magmaForDB(_:floor:) entry
//  point bit-identical to the production source so the tests exercise the
//  same code path the AU renders with.
//

import simd

enum SpectrogramColorMap {

    static let magma: [SIMD4<UInt8>] = {
        var colors = [SIMD4<UInt8>](repeating: .zero, count: 256)
        for i in 0..<256 {
            let t = Float(i) / 255.0
            let (r, g, b) = magmaColor(t)
            colors[i] = SIMD4(
                UInt8(clamping: Int(r * 255)),
                UInt8(clamping: Int(g * 255)),
                UInt8(clamping: Int(b * 255)),
                255
            )
        }
        return colors
    }()

    private static func magmaColor(_ t: Float) -> (Float, Float, Float) {
        // Anchors must match ConjureDSPExtension/UI/SpectrogramColorMap.swift:
        //  0.0 #0D0F1A deep navy     (0.051, 0.059, 0.102)
        //  0.5 #B06EFF soft purple   (0.690, 0.431, 1.000)
        //  1.0 #FFD166 warm gold     (1.000, 0.820, 0.400)
        let r: Float
        let g: Float
        let b: Float

        if t < 0.5 {
            let s = t / 0.5
            r = 0.051 + s * (0.690 - 0.051)
            g = 0.059 + s * (0.431 - 0.059)
            b = 0.102 + s * (1.000 - 0.102)
        } else {
            let s = (t - 0.5) / 0.5
            r = 0.690 + s * (1.000 - 0.690)
            g = 0.431 + s * (0.820 - 0.431)
            b = 1.000 + s * (0.400 - 1.000)
        }

        return (min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
    }

    static func magmaForDB(_ db: Float, floor: Float = -120.0) -> SIMD4<UInt8> {
        let normalized = (db - floor) / (0.0 - floor)
        let clamped = min(max(normalized, 0), 1)
        let index = Int(clamped * 255)
        return magma[index]
    }
}
