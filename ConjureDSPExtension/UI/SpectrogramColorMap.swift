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
    /// Ramp: deep navy → dark plum → soft purple → warm gold.
    ///
    /// Four anchors tuned to approximate matplotlib magma's perceptually-
    /// linear luminance curve while preserving brand colors at the loud end:
    ///   navy ≈ 0.06, dark plum ≈ 0.16, soft purple ≈ 0.57, gold ≈ 0.83.
    ///
    /// Earlier two-segment design (navy → soft purple → gold at t=0.5)
    /// placed the brand `#B06EFF` at the midpoint — luminance 0.57. Under a
    /// dB→t linear normalization this painted off-fundamental sidelobes
    /// (e.g. −60 dB at t=0.5 with floor=−120) as fully saturated bright
    /// purple even though they're below typical listening thresholds. The
    /// dark-plum anchor at t=0.5 keeps the low-dB range dark while the
    /// shifted-up brand purple at t=0.75 reserves the bright purple for
    /// loud signal content.
    private static func magmaColor(_ t: Float) -> (Float, Float, Float) {
        // Anchor colors (sRGB, 0–1):
        //  0.00 #0D0F1A deep navy     (0.051, 0.059, 0.102)  L ≈ 0.06
        //  0.50 #4A1F70 dark plum     (0.290, 0.122, 0.439)  L ≈ 0.16
        //  0.75 #B06EFF soft purple   (0.690, 0.431, 1.000)  L ≈ 0.57
        //  1.00 #FFD166 warm gold     (1.000, 0.820, 0.400)  L ≈ 0.83
        let r: Float
        let g: Float
        let b: Float

        if t < 0.5 {
            // Deep navy → dark plum
            let s = t / 0.5
            r = 0.051 + s * (0.290 - 0.051)
            g = 0.059 + s * (0.122 - 0.059)
            b = 0.102 + s * (0.439 - 0.102)
        } else if t < 0.75 {
            // Dark plum → soft purple (brand)
            let s = (t - 0.5) / 0.25
            r = 0.290 + s * (0.690 - 0.290)
            g = 0.122 + s * (0.431 - 0.122)
            b = 0.439 + s * (1.000 - 0.439)
        } else {
            // Soft purple → warm gold
            let s = (t - 0.75) / 0.25
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

    /// Branded diverging ramp using the ConjureDSP palette (`assets/palette.md`).
    /// Cyan (cut) → deep navy (neutral) → soft purple → warm gold (boost).
    /// The boost half mirrors the magma ramp's navy→purple→gold anchors so the
    /// two colormaps feel like a family; the cut half uses electric cyan for
    /// unambiguous cool/warm separation.
    ///
    /// Anchors (sRGB, 0–1):
    ///  0.00 #00E5FF electric cyan  (0.000, 0.898, 1.000)
    ///  0.50 #0D0F1A deep navy      (0.051, 0.059, 0.102)
    ///  0.75 #B06EFF soft purple    (0.690, 0.431, 1.000)
    ///  1.00 #FFD166 warm gold      (1.000, 0.820, 0.400)
    private static func divergingColor(_ t: Float) -> (Float, Float, Float) {
        let r: Float
        let g: Float
        let b: Float

        if t < 0.5 {
            // Cyan → navy
            let s = t / 0.5
            r = 0.000 + s * (0.051 - 0.000)
            g = 0.898 + s * (0.059 - 0.898)
            b = 1.000 + s * (0.102 - 1.000)
        } else if t < 0.75 {
            // Navy → soft purple
            let s = (t - 0.5) / 0.25
            r = 0.051 + s * (0.690 - 0.051)
            g = 0.059 + s * (0.431 - 0.059)
            b = 0.102 + s * (1.000 - 0.102)
        } else {
            // Soft purple → warm gold
            let s = (t - 0.75) / 0.25
            r = 0.690 + s * (1.000 - 0.690)
            g = 0.431 + s * (0.820 - 0.431)
            b = 1.000 + s * (0.400 - 1.000)
        }

        return (min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
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
