//
//  ParameterSlidersView.swift
//  ConjureDSPExtension
//
//  Created by Michael Jancsy on 3/4/26.
//

import SwiftUI

private let panelAnimation = Animation.easeOut(duration: 0.15)

struct ParameterSlidersView: View {
    @ObservedObject var parameterState: ParameterState
    @State private var isExpanded: Bool = true

    /// Indices of parameters to display, from the declared param names.
    private var visibleIndices: [Int] {
        guard let names = parameterState.paramNames else { return [] }
        return Array(names.keys).sorted()
    }

    private func label(for index: Int) -> String {
        parameterState.paramNames?[index] ?? "Param \(index)"
    }

    private func metadata(for index: Int) -> ConjureDSPExtensionAudioUnit.ParamMetadata? {
        guard let meta = parameterState.paramMetadata, index < meta.count else { return nil }
        return meta[index]
    }

    var body: some View {
        if !visibleIndices.isEmpty {
            VStack(spacing: 0) {
                // Custom disclosure header — gives us full animation control
                Button(action: {
                    withAnimation(panelAnimation) { isExpanded.toggle() }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(panelAnimation, value: isExpanded)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Parameters")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(spacing: 4) {
                        ForEach(visibleIndices, id: \.self) { index in
                            ParameterSliderRow(
                                label: label(for: index),
                                value: parameterState.binding(for: index),
                                metadata: metadata(for: index)
                            )
                        }
                    }
                    // Cap the row block at a comfortable width. NOT
                    // containerRelativeFrame: that sizes to the *window*, so
                    // inside the editor panel's column it demanded 0.75×window
                    // and overflowed the column, clipping the terminal panel.
                    .frame(maxWidth: 520)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .clipped()
            .accessibilityIdentifier("parameterSlidersPanel")
        }
    }
}

struct ParameterSliderRow: View {
    let label: String
    @Binding var value: Float
    let metadata: ConjureDSPExtensionAudioUnit.ParamMetadata?

    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var fieldFocused: Bool

    /// True while editText is empty (still starting) or parses as a valid Float.
    private var isEditTextValid: Bool {
        editText.isEmpty || Float(editText) != nil
    }

    private var fieldHelpText: String {
        let lo = metadata?.min ?? 0
        let hi = metadata?.max ?? 1
        let unit = (metadata?.unit.isEmpty == false) ? " \(metadata!.unit)" : ""
        let range = "\(String(format: "%g", lo))–\(String(format: "%g", hi))\(unit)"
        if !isEditTextValid {
            return "\"\(editText)\" is not a valid number. Enter a value between \(range)."
        }
        return "Valid range: \(range). Press Return to apply, Escape to cancel."
    }

    private var isSlider: Bool {
        !(metadata?.isToggle ?? false) && !(metadata?.isChoice ?? false)
    }

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
            } else if let meta = metadata, meta.isInteger {
                DSPSlider(value: integerBinding, range: meta.min...meta.max, onDoubleTap: { value = meta.`default`.rounded() })
                    .accessibilityIdentifier("\(label)Slider")
            } else if let meta = metadata {
                DSPSlider(value: $value, range: meta.min...meta.max, onDoubleTap: { value = meta.`default` })
                    .accessibilityIdentifier("\(label)Slider")
            } else {
                DSPSlider(value: $value, range: 0...1, onDoubleTap: { value = 0.5 })
                    .accessibilityIdentifier("\(label)Slider")
            }

            // Value display — tappable for inline editing on slider params
            if isEditing {
                TextField("", text: $editText)
                    .font(.caption.monospaced())
                    .frame(width: 64)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isEditTextValid
                                ? Color.accentColor.opacity(0.10)
                                : Color.red.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isEditTextValid
                                ? Color.accentColor.opacity(0.5)
                                : Color.red.opacity(0.8), lineWidth: 1)
                    )
                    .help(fieldHelpText)
                    .focused($fieldFocused)
                    .onSubmit { commitEdit(exitOnError: false) }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { commitEdit(exitOnError: true) }
                    }
                    .onKeyPress(.escape) {
                        isEditing = false
                        return .handled
                    }
            } else {
                Text(formattedValue)
                    .font(.caption.monospaced())
                    .frame(width: 64, alignment: .trailing)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                    .accessibilityIdentifier("\(label)Value")
                    .onTapGesture {
                        guard isSlider else { return }
                        editText = String(format: "%g", value)
                        isEditing = true
                        fieldFocused = true
                    }
            }
        }
    }

    /// - exitOnError: true when triggered by losing focus (blur) — always exits edit mode.
    ///                false when triggered by Return — keeps edit mode open so user can fix invalid input.
    private func commitEdit(exitOnError: Bool = true) {
        guard let parsed = Float(editText) else {
            if exitOnError {
                isEditing = false   // blur: silently revert to old value
            } else {
                fieldFocused = true // Return with invalid input: stay in edit mode (red border is the signal)
            }
            return
        }
        let lo = metadata?.min ?? 0
        let hi = metadata?.max ?? 1
        let snapped = (metadata?.isInteger ?? false) ? parsed.rounded() : parsed
        value = max(lo, min(hi, snapped))
        isEditing = false
    }

    private var toggleBinding: Binding<Bool> {
        Binding<Bool>(
            get: { value >= 0.5 },
            set: { value = $0 ? 1.0 : 0.0 }
        )
    }

    private func choiceBinding(optionCount: Int) -> Binding<Int> {
        Binding<Int>(
            get: {
                let idx = Int(value.rounded())
                return max(0, min(idx, optionCount - 1))
            },
            set: { value = Float($0) }
        )
    }

    /// Slider binding that snaps the value to the nearest integer (clamped to
    /// `[meta.min, meta.max]`) before forwarding it. Used for `style="integer"`
    /// params so dragging the slider feels detented and matches what the script
    /// and DAW will see.
    private var integerBinding: Binding<Float> {
        Binding<Float>(
            get: { value },
            set: { newValue in
                let lo = metadata?.min ?? 0
                let hi = metadata?.max ?? 1
                value = max(lo, min(hi, newValue.rounded()))
            }
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
        return ConjureDSPExtensionAudioUnit.formatParamValue(value, unit: meta.unit, isInteger: meta.isInteger)
    }
}

/// Custom slider with a styled track and thumb, replacing the stock SwiftUI Slider.
private struct DSPSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var onDoubleTap: (() -> Void)? = nil

    @State private var isDragging = false

    private var fraction: CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    /// Interpolated fill color: soft purple `#B06EFF` at fraction 0 → ice blue `#7B9FFF` at fraction 1.
    private var fillColor: Color {
        let f = Double(max(0, min(1, fraction)))
        let r = 0.690 + f * (0.482 - 0.690)
        let g = 0.431 + f * (0.624 - 0.431)
        let b = 1.000 // both anchor colors have B = 1.0
        return Color(red: r, green: g, blue: b)
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

                // Track fill — purple at 0 → ice blue at 1
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(fillColor)
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
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { onDoubleTap?() }
            )
        }
        .frame(height: 20)
    }
}
