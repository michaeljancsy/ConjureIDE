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

    var body: some View {
        DisclosureGroup("Parameters", isExpanded: $isExpanded) {
            VStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { index in
                    ParameterSliderRow(
                        label: "Param \(index)",
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

struct ParameterSliderRow: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 52, alignment: .leading)

            Slider(value: $value, in: 0...1)
                .accessibilityIdentifier("\(label)Slider")

            Text(String(format: "%.3f", value))
                .font(.caption.monospaced())
                .frame(width: 44, alignment: .trailing)
                .accessibilityIdentifier("\(label)Value")
        }
    }
}
