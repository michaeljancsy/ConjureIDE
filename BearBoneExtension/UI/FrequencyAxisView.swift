//
//  FrequencyAxisView.swift
//  BearBoneExtension
//
//  Frequency axis labels for spectrogram display.
//  Supports Hz and musical note name display.
//

import SwiftUI

/// Overlay view that draws frequency tick marks and labels on the left edge
/// of a spectrogram.
struct FrequencyAxisView: View {
    var frequencyScale: FrequencyScale
    var sampleRate: Float = 44100.0
    var showNoteNames: Bool = false

    /// Standard Hz tick marks for audio spectrograms
    private static let hzTicks: [Float] = [
        20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000,
    ]

    /// Note names with their Hz values (A0 through C8)
    private static let noteTicks: [(name: String, hz: Float)] = [
        ("A0", 27.5),
        ("C1", 32.7),
        ("C2", 65.4),
        ("A2", 110),
        ("C3", 130.8),
        ("A3", 220),
        ("C4", 261.6),
        ("A4", 440),
        ("C5", 523.3),
        ("A5", 880),
        ("C6", 1046.5),
        ("A6", 1760),
        ("C7", 2093),
        ("A7", 3520),
        ("C8", 4186),
    ]

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let nyquist = sampleRate / 2.0

            ForEach(tickPositions(height: Float(height), nyquist: nyquist), id: \.label) { tick in
                // Tick mark and label
                HStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 4, height: 1)
                    Text(tick.label)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .position(x: 20, y: CGFloat(height) - CGFloat(tick.y))
            }
        }
        .allowsHitTesting(false) // Don't intercept clicks
    }

    private struct TickInfo: Hashable {
        let label: String
        let y: Float
    }

    private func tickPositions(height: Float, nyquist: Float) -> [TickInfo] {
        var ticks: [TickInfo] = []

        if showNoteNames {
            for note in Self.noteTicks {
                guard note.hz < nyquist && note.hz >= 20 else { continue }
                let normalizedFreq = note.hz / nyquist
                let y = frequencyScale.binToPixelY(
                    bin: Int(normalizedFreq * 1024),
                    binCount: 1024,
                    height: Int(height),
                    minFreqNorm: 20.0 / nyquist
                )
                if y > 10 && y < height - 10 {
                    ticks.append(TickInfo(label: note.name, y: y))
                }
            }
        } else {
            for hz in Self.hzTicks {
                guard hz < nyquist && hz >= 20 else { continue }
                let normalizedFreq = hz / nyquist
                let y = frequencyScale.binToPixelY(
                    bin: Int(normalizedFreq * 1024),
                    binCount: 1024,
                    height: Int(height),
                    minFreqNorm: 20.0 / nyquist
                )
                if y > 10 && y < height - 10 {
                    ticks.append(TickInfo(label: formatHz(hz), y: y))
                }
            }
        }

        return ticks
    }

    private func formatHz(_ hz: Float) -> String {
        if hz >= 1000 {
            let kHz = hz / 1000.0
            if kHz == Float(Int(kHz)) {
                return "\(Int(kHz))k"
            }
            return String(format: "%.1fk", kHz)
        }
        return "\(Int(hz))"
    }
}
