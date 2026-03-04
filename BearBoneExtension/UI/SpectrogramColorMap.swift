//
//  SpectrogramColorMap.swift
//  BearBoneExtension
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

    /// Magma colormap interpolation (approximation of matplotlib's magma).
    private static func magmaColor(_ t: Float) -> (Float, Float, Float) {
        // Simplified magma: black → dark purple → magenta → orange → yellow
        let r: Float
        let g: Float
        let b: Float

        if t < 0.25 {
            // Black to dark purple
            let s = t / 0.25
            r = s * 0.27
            g = 0
            b = s * 0.33
        } else if t < 0.5 {
            // Dark purple to magenta
            let s = (t - 0.25) / 0.25
            r = 0.27 + s * 0.45
            g = s * 0.05
            b = 0.33 + s * 0.25
        } else if t < 0.75 {
            // Magenta to orange
            let s = (t - 0.5) / 0.25
            r = 0.72 + s * 0.23
            g = 0.05 + s * 0.40
            b = 0.58 - s * 0.45
        } else {
            // Orange to yellow
            let s = (t - 0.75) / 0.25
            r = 0.95 + s * 0.05
            g = 0.45 + s * 0.50
            b = 0.13 - s * 0.08
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

    /// Blue (cut) → dark gray (neutral) → red (boost)
    private static func divergingColor(_ t: Float) -> (Float, Float, Float) {
        if t < 0.5 {
            // Blue (cut) → dark gray
            let s = t / 0.5
            let r = s * 0.2
            let g = s * 0.2
            let b = 0.6 + s * (0.2 - 0.6)
            return (r, g, b)
        } else {
            // Dark gray → red (boost)
            let s = (t - 0.5) / 0.5
            let r = 0.2 + s * 0.7
            let g = 0.2 - s * 0.15
            let b = 0.2 - s * 0.15
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
