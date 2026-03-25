//
//  FrequencyAxisView.swift
//  ConjureDSPExtension
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

    /// Note names with their Hz values (C1 through C8)
    private static let noteTicks: [(name: String, hz: Float)] = [
        ("C1", 32.7),
        ("C2", 65.4),
        ("C3", 130.8),
        ("C4", 261.6),
        ("C5", 523.3),
        ("C6", 1046.5),
        ("C7", 2093),
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

        // Remove labels that are too close together (minimum 14px apart)
        let minSpacing: Float = 14
        var filtered: [TickInfo] = []
        for tick in ticks.sorted(by: { $0.y < $1.y }) {
            if let last = filtered.last, abs(tick.y - last.y) < minSpacing {
                continue
            }
            filtered.append(tick)
        }
        return filtered
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
