//
//  ExportAUMainView.swift
//  ConjureDSPExportAUTemplateExtension
//

import SwiftUI

struct ExportAUMainView: View {
    @ObservedObject var parameterState: ExportParameterState
    let config: RuntimeConfig?
    let pythonRuntimeMissing: Bool

    var body: some View {
        if pythonRuntimeMissing {
            PythonRuntimeErrorView(presetName: config?.presetName)
        } else {
            VStack(spacing: 12) {
                Text(config?.presetName ?? "ConjureDSP Export")
                    .font(.headline)
                    .padding(.top, 12)

                Divider()

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(0..<parameterState.paramCount, id: \.self) { index in
                            ExportParamSliderRow(
                                label: config?.paramLabel(at: index) ?? "Param \(index + 1)",
                                value: parameterState.binding(for: index),
                                metadata: parameterState.metadata(for: index)
                            )
                        }
                    }
                    .padding(.horizontal)
                }

                Text("Made with ConjureDSP")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }
}

struct ExportParamSliderRow: View {
    let label: String
    @Binding var value: Float
    let metadata: ExportParamMetadata?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 60, alignment: .leading)
                .lineLimit(1)

            if let meta = metadata {
                Slider(value: $value, in: meta.min...meta.max)
            } else {
                Slider(value: $value, in: 0...1)
            }

            Text(formattedValue)
                .font(.caption.monospaced())
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var formattedValue: String {
        guard let meta = metadata else {
            return String(format: "%.3f", value)
        }
        return ExportAUAudioUnit.formatParamValue(value, unit: meta.unit)
    }
}
