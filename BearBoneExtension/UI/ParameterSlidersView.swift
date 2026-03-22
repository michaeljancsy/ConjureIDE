//
//  ParameterSlidersView.swift
//  BearBoneExtension
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

    var body: some View {
        if !visibleIndices.isEmpty {
            DisclosureGroup("Parameters", isExpanded: $isExpanded) {
                VStack(spacing: 4) {
                    ForEach(visibleIndices, id: \.self) { index in
                        ParameterSliderRow(
                            label: label(for: index),
                            value: parameterState.binding(for: index)
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

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
                .lineLimit(1)

            Slider(value: $value, in: 0...1)
                .accessibilityIdentifier("\(label)Slider")

            Text(String(format: "%.3f", value))
                .font(.caption.monospaced())
                .frame(width: 44, alignment: .trailing)
                .accessibilityIdentifier("\(label)Value")
        }
    }
}
