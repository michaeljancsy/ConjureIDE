//
//  SpectrogramSidePanel.swift
//  BearBoneExtension
//
//  Collapsible side panel containing stacked input/output/difference spectrograms.
//

import SwiftUI

/// Side panel with three stacked spectrograms (input, output, difference)
/// and a mini toolbar for configuration.
struct SpectrogramSidePanel: View {
    @ObservedObject var captureManager: AudioCaptureManager
    @Binding var frequencyScale: FrequencyScale
    @Binding var fftSizeIndex: Int
    @Binding var showNoteNames: Bool

    static let fftSizes = [512, 1024, 2048, 4096]

    var body: some View {
        VStack(spacing: 0) {
            // Mini toolbar — uses GeometryReader to constrain controls to panel width
            GeometryReader { geo in
                HStack(spacing: 6) {
                    // Frequency scale picker
                    Picker(selection: $frequencyScale) {
                        ForEach(FrequencyScale.allCases) { scale in
                            Text(scale.rawValue).tag(scale)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Spacer(minLength: 0)

                    // FFT size picker
                    Picker("FFT", selection: $fftSizeIndex) {
                        ForEach(0..<Self.fftSizes.count, id: \.self) { i in
                            Text("\(Self.fftSizes[i])").tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: fftSizeIndex) { _, newValue in
                        captureManager.fftSize = Self.fftSizes[newValue]
                    }

                    // Hz / Notes toggle
                    Button {
                        showNoteNames.toggle()
                    } label: {
                        Image(systemName: showNoteNames ? "music.note" : "number")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help(showNoteNames ? "Show Hz labels" : "Show note names")
                }
                .padding(.horizontal, 6)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: 28)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .controlSize(.small)
            .background(.bar)

            Divider()

            // Three stacked spectrograms
            VStack(spacing: 1) {
                // Input spectrogram
                VStack(alignment: .leading, spacing: 2) {
                    Text("Input")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                        .padding(.top, 2)

                    SpectrogramView(
                        captureManager: captureManager,
                        channel: .input,
                        frequencyScale: frequencyScale
                    )
                }

                Divider()

                // Output spectrogram
                VStack(alignment: .leading, spacing: 2) {
                    Text("Output")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                        .padding(.top, 2)

                    SpectrogramView(
                        captureManager: captureManager,
                        channel: .output,
                        frequencyScale: frequencyScale
                    )
                }

                Divider()

                // Difference spectrogram
                VStack(alignment: .leading, spacing: 2) {
                    Text("Difference")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                        .padding(.top, 2)

                    SpectrogramView(
                        captureManager: captureManager,
                        channel: .difference,
                        frequencyScale: frequencyScale
                    )
                }

                Divider()

                // Normalized difference spectrogram
                VStack(alignment: .leading, spacing: 2) {
                    Text("Normalized Diff")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                        .padding(.top, 2)

                    SpectrogramView(
                        captureManager: captureManager,
                        channel: .normalizedDifference,
                        frequencyScale: frequencyScale
                    )
                }
            }
        }
        .accessibilityIdentifier("spectrogramSidePanel")
    }
}
