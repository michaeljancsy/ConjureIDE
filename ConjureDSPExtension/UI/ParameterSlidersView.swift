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

            if let meta = metadata {
                Slider(value: $value, in: meta.min...meta.max)
                    .accessibilityIdentifier("\(label)Slider")
            } else {
                Slider(value: $value, in: 0...1)
                    .accessibilityIdentifier("\(label)Slider")
            }

            Text(formattedValue)
                .font(.caption.monospaced())
                .frame(width: 64, alignment: .trailing)
                .accessibilityIdentifier("\(label)Value")
        }
    }

    private var formattedValue: String {
        guard let meta = metadata else {
            return String(format: "%.3f", value)
        }
        return ConjureDSPExtensionAudioUnit.formatParamValue(value, unit: meta.unit)
    }
}
