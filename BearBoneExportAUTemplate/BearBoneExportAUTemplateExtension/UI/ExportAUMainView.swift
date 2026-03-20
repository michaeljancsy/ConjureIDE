//
//  ExportAUMainView.swift
//  BearBoneExportAUTemplateExtension
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
                Text(config?.presetName ?? "BearBone Export")
                    .font(.headline)
                    .padding(.top, 12)

                Divider()

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(0..<parameterState.paramCount, id: \.self) { index in
                            HStack(spacing: 8) {
                                Text(config?.paramLabel(at: index) ?? "Param \(index + 1)")
                                    .font(.caption)
                                    .frame(width: 60, alignment: .leading)
                                Slider(value: parameterState.binding(for: index), in: 0...1)
                                Text(String(format: "%.3f", parameterState.values[index]))
                                    .font(.caption.monospaced())
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                Text("Made with BearBone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }
}
