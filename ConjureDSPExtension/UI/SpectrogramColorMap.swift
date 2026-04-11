//
//  SpectrogramColorMap.swift
//  ConjureDSPExtension
//
//  Pre-computed color lookup tables for spectrogram rendering.
//

import SwiftUI

/// Color maps for spectrogram visualization.
enum SpectrogramColorMap {

    // MARK: - Magma Color Map (absolute magnitude)

    /// 256-entry Magma/Inferno-style color map.
    /// Maps normalized magnitude [0, 1] to RGBA pixel values.
    /// 0 = silence (dark purple/black), 1 = loud (bright yellow).
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

    /// Branded colormap using the ConjureDSP palette (`assets/palette.md`).
    /// Ramp: deep navy → soft purple → warm gold.
    ///
    /// Three anchors chosen so that perceived luminance (0.299R + 0.587G + 0.114B)
    /// ramps roughly linearly across the range:
    ///   navy ≈ 0.06, purple ≈ 0.57, gold ≈ 0.83.
    /// Brushed metal and hot pink anchors were dropped — metal was too close to
    /// navy to earn its own segment, and hot pink had the same luminance as purple,
    /// flattening the mid-loud portion of the spectrogram.
    private static func magmaColor(_ t: Float) -> (Float, Float, Float) {
        // Anchor colors (sRGB, 0–1):
        //  0.0 #0D0F1A deep navy     (0.051, 0.059, 0.102)
        //  0.5 #B06EFF soft purple   (0.690, 0.431, 1.000)
        //  1.0 #FFD166 warm gold     (1.000, 0.820, 0.400)
        let r: Float
        let g: Float
        let b: Float

        if t < 0.5 {
            // Deep navy → soft purple
            let s = t / 0.5
            r = 0.051 + s * (0.690 - 0.051)
            g = 0.059 + s * (0.431 - 0.059)
            b = 0.102 + s * (1.000 - 0.102)
        } else {
            // Soft purple → warm gold
            let s = (t - 0.5) / 0.5
            r = 0.690 + s * (1.000 - 0.690)
            g = 0.431 + s * (0.820 - 0.431)
            b = 1.000 + s * (0.400 - 1.000)
        }

        return (min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
    }

    // MARK: - Diverging Color Map (difference)

    /// 256-entry diverging color map for difference spectrogram.
    /// Maps normalized difference [-1, 1] to RGBA pixel values.
    /// Index 0 = maximum cut (blue), 128 = neutral (dark gray), 255 = maximum boost (red).
    static let diverging: [SIMD4<UInt8>] = {
        var colors = [SIMD4<UInt8>](repeating: .zero, count: 256)
        for i in 0..<256 {
            let t = Float(i) / 255.0 // 0...1
            let (r, g, b) = divergingColor(t)
            colors[i] = SIMD4(
                UInt8(clamping: Int(r * 255)),
                UInt8(clamping: Int(g * 255)),
                UInt8(clamping: Int(b * 255)),
                255
            )
        }
        return colors
    }()

    /// Blue (cut) → black (neutral) → red (boost)
    private static func divergingColor(_ t: Float) -> (Float, Float, Float) {
        if t < 0.5 {
            // Blue (cut) → black
            let s = t / 0.5
            let r: Float = 0
            let g: Float = 0
            let b = 0.6 * (1.0 - s)
            return (r, g, b)
        } else {
            // Black → red (boost)
            let s = (t - 0.5) / 0.5
            let r = s * 0.9
            let g: Float = 0
            let b: Float = 0
            return (r, g, b)
        }
    }

    // MARK: - Lookup Helpers

    /// Look up a magma color for a dB value.
    /// - Parameter db: Magnitude in dB (floorDB...0)
    /// - Returns: Color map entry
    static func magmaForDB(_ db: Float, floor: Float = -120.0) -> SIMD4<UInt8> {
        let normalized = (db - floor) / (0.0 - floor) // 0 = silence, 1 = loud
        let clamped = min(max(normalized, 0), 1)
        let index = Int(clamped * 255)
        return magma[index]
    }

    /// Look up a diverging color for a difference dB value.
    /// - Parameter diffDB: Difference in dB (negative = cut, positive = boost)
    /// - Parameter range: Maximum absolute dB range
    /// - Returns: Color map entry
    static func divergingForDB(_ diffDB: Float, range: Float = 40.0) -> SIMD4<UInt8> {
        let normalized = (diffDB / range + 1.0) / 2.0 // map [-range, range] to [0, 1]
        let clamped = min(max(normalized, 0), 1)
        let index = Int(clamped * 255)
        return diverging[index]
    }
}
