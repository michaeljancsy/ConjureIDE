//
//  FrequencyScale.swift
//  BearBoneExtension
//
//  Frequency axis scale types and mapping functions for spectrogram display.
//

import Foundation

/// Frequency axis scale for spectrogram display.
enum FrequencyScale: String, CaseIterable, Identifiable {
    case log = "Log"
    case linear = "Linear"
    case mel = "Mel"

    var id: String { rawValue }

    /// Map a normalized frequency (0...1 where 0=minFreq, 1=maxFreq) to a
    /// normalized position (0...1) on the display axis.
    ///
    /// - Parameters:
    ///   - normalizedFreq: Linear frequency position in 0...1
    /// - Returns: Display position in 0...1
    func mapToDisplay(_ normalizedFreq: Float) -> Float {
        switch self {
        case .linear:
            return normalizedFreq
        case .log:
            // Log scale: equal spacing per octave
            let minLog: Float = 0.001
            let clamped = max(normalizedFreq, minLog)
            let logMin = log2f(minLog)
            let logMax: Float = 0.0
            return (log2f(clamped) - logMin) / (logMax - logMin)
        case .mel:
            // Mel scale: 2595 * log10(1 + f/700)
            let minLog: Float = 0.001
            let clamped = max(normalizedFreq, minLog)
            let melVal: Float = 2595.0 * log10f(1.0 + clamped * 22050.0 / 700.0)
            let melMax: Float = 2595.0 * log10f(1.0 + 22050.0 / 700.0)
            let melMin: Float = 2595.0 * log10f(1.0 + minLog * 22050.0 / 700.0)
            return (melVal - melMin) / (melMax - melMin)
        }
    }

    /// Map an FFT bin index to a vertical pixel position (0 = bottom, height = top).
    ///
    /// - Parameters:
    ///   - bin: FFT bin index (0 = DC, binCount-1 = Nyquist)
    ///   - binCount: Total number of FFT bins (fftSize / 2)
    ///   - height: Pixel height of the spectrogram
    ///   - minFreqNorm: Minimum displayed frequency as fraction of Nyquist (e.g. 20/22050)
    /// - Returns: Pixel Y position (0 = bottom of spectrogram)
    func binToPixelY(bin: Int, binCount: Int, height: Int, minFreqNorm: Float = 20.0 / 22050.0) -> Float {
        let normalizedFreq = Float(bin) / Float(binCount)
        let clamped = max(normalizedFreq, minFreqNorm)

        let displayPos: Float
        switch self {
        case .linear:
            displayPos = clamped
        case .log:
            let logMin = log2f(minFreqNorm)
            let logMax: Float = 0.0 // log2(1.0) = 0
            displayPos = (log2f(clamped) - logMin) / (logMax - logMin)
        case .mel:
            let melVal: Float = 2595.0 * log10f(1.0 + clamped * 22050.0 / 700.0)
            let melMax: Float = 2595.0 * log10f(1.0 + 22050.0 / 700.0)
            let melMin: Float = 2595.0 * log10f(1.0 + minFreqNorm * 22050.0 / 700.0)
            displayPos = (melVal - melMin) / (melMax - melMin)
        }

        return displayPos * Float(height)
    }
}
