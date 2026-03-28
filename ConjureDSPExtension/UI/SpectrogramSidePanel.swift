//
//  SpectrogramSidePanel.swift
//  ConjureDSPExtension
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

    @State private var showInput = true
    @State private var showOutput = true
    @State private var showDifference = true
    @State private var showNormalizedDiff = true
    @State private var isPaused = false

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

                    // Pause / Resume
                    Button {
                        isPaused.toggle()
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help(isPaused ? "Resume spectrogram" : "Pause spectrogram")
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

            // Stacked spectrograms (collapsible, expanded sections fill space)
            VStack(spacing: 1) {
                spectrogramSection("Input", channel: .input, isExpanded: $showInput)
                Divider()
                spectrogramSection("Output", channel: .output, isExpanded: $showOutput)
                Divider()
                spectrogramSection("Difference", channel: .difference, isExpanded: $showDifference)
                Divider()
                spectrogramSection("Normalized Diff", channel: .normalizedDifference, isExpanded: $showNormalizedDiff)
            }
        }
        .accessibilityIdentifier("spectrogramSidePanel")
    }

    @ViewBuilder
    private func spectrogramSection(_ title: String, channel: SpectrogramChannel, isExpanded: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                SpectrogramView(
                    captureManager: captureManager,
                    channel: channel,
                    frequencyScale: frequencyScale,
                    isPaused: isPaused
                )
                .overlay(alignment: .leading) {
                    FrequencyAxisView(
                        frequencyScale: frequencyScale,
                        showNoteNames: showNoteNames
                    )
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}
