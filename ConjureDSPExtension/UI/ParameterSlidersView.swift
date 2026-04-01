//
//  ParameterSlidersView.swift
//  ConjureDSPExtension
//
//  Created by Michael Jancsy on 3/4/26.
//

import SwiftUI

struct ParameterSlidersView: View {
    @ObservedObject var parameterState: ParameterState
    @State private var isExpanded: Bool = true

    /// Indices of parameters to display, from the declared param names.
    private var visibleIndices: [Int] {
        guard let names = parameterState.paramNames else { return [] }
        return Array(names.keys).sorted()
    }

    /// Label for a parameter at the given index.
    private func label(for index: Int) -> String {
        parameterState.paramNames?[index] ?? "Param \(index)"
    }

    /// Metadata for a parameter at the given index (nil for legacy 0–1 params).
    private func metadata(for index: Int) -> ConjureDSPExtensionAudioUnit.ParamMetadata? {
        guard let meta = parameterState.paramMetadata, index < meta.count else { return nil }
        return meta[index]
    }

    var body: some View {
        if !visibleIndices.isEmpty {
            DisclosureGroup("Parameters", isExpanded: $isExpanded) {
                VStack(spacing: 4) {
                    ForEach(visibleIndices, id: \.self) { index in
                        ParameterSliderRow(
                            label: label(for: index),
                            value: parameterState.binding(for: index),
                            metadata: metadata(for: index)
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal)
            .accessibilityIdentifier("parameterSlidersPanel")
        }
    }
}

struct ParameterSliderRow: View {
    let label: String
    @Binding var value: Float
    let metadata: ConjureDSPExtensionAudioUnit.ParamMetadata?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)

            if let meta = metadata, meta.isToggle {
                Spacer()
                Toggle("", isOn: toggleBinding)
                    .labelsHidden()
                    .accessibilityIdentifier("\(label)Toggle")
            } else if let meta = metadata, meta.isChoice, let options = meta.options {
                Spacer()
                Picker("", selection: choiceBinding(optionCount: options.count)) {
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                        Text(opt).tag(idx)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("\(label)Picker")
            } else if let meta = metadata {
                DSPSlider(value: $value, range: meta.min...meta.max)
                    .accessibilityIdentifier("\(label)Slider")
            } else {
                DSPSlider(value: $value, range: 0...1)
                    .accessibilityIdentifier("\(label)Slider")
            }

            // Recessed value display
            Text(formattedValue)
                .font(.caption.monospaced())
                .frame(width: 64, alignment: .trailing)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.06))
                )
                .accessibilityIdentifier("\(label)Value")
        }
    }

    /// Bridge Float 0/1 to Bool for SwiftUI Toggle.
    private var toggleBinding: Binding<Bool> {
        Binding<Bool>(
            get: { value >= 0.5 },
            set: { value = $0 ? 1.0 : 0.0 }
        )
    }

    /// Bridge Float index to Int for SwiftUI Picker.
    private func choiceBinding(optionCount: Int) -> Binding<Int> {
        Binding<Int>(
            get: {
                let idx = Int(value.rounded())
                return max(0, min(idx, optionCount - 1))
            },
            set: { value = Float($0) }
        )
    }

    private var formattedValue: String {
        if let meta = metadata, meta.isToggle {
            return value >= 0.5 ? "On" : "Off"
        }
        if let meta = metadata, meta.isChoice, let options = meta.options {
            let idx = Int(value.rounded())
            if idx >= 0, idx < options.count {
                return options[idx]
            }
        }
        guard let meta = metadata else {
            return String(format: "%.3f", value)
        }
        return ConjureDSPExtensionAudioUnit.formatParamValue(value, unit: meta.unit)
    }
}

/// Custom slider with a styled track and thumb, replacing the stock SwiftUI Slider.
private struct DSPSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    @State private var isDragging = false

    private var fraction: CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { geo in
            let trackHeight: CGFloat = 3
            let thumbDiameter: CGFloat = 14
            let usableWidth = geo.size.width - thumbDiameter
            let thumbX = thumbDiameter / 2 + fraction * usableWidth

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumbDiameter / 2)

                // Track fill
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.accentColor)
                    .frame(width: max(thumbDiameter / 2, thumbX), height: trackHeight)
                    .padding(.leading, thumbDiameter / 2)
                    .clipped()

                // Thumb
                Circle()
                    .fill(Color(nsColor: .controlColor))
                    .shadow(color: .black.opacity(isDragging ? 0.35 : 0.20), radius: 2, x: 0, y: 1)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .offset(x: thumbX - thumbDiameter / 2)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                            .frame(width: thumbDiameter, height: thumbDiameter)
                            .offset(x: thumbX - thumbDiameter / 2)
                    )
            }
            .frame(maxHeight: .infinity)
            // Invisible full-height hit target
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let newFraction = max(0, min(1, (drag.location.x - thumbDiameter / 2) / usableWidth))
                        value = range.lowerBound + Float(newFraction) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: 20)
    }
}
