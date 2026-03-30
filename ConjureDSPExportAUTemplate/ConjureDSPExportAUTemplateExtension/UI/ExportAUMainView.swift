//
//  ExportAUMainView.swift
//  ConjureDSPExportAUTemplateExtension
//

import SwiftUI

struct ExportAUMainView: View {
    @ObservedObject var parameterState: ExportParameterState
    let config: RuntimeConfig?
    let pythonRuntimeMissing: Bool
    var loadError: String? = nil
    @State private var errorCopied = false

    var body: some View {
        if pythonRuntimeMissing {
            PythonRuntimeErrorView(presetName: config?.presetName)
        } else {
            VStack(spacing: 12) {
                Text(config?.presetName ?? "ConjureDSP Export")
                    .font(.headline)
                    .padding(.top, 12)

                if let error = loadError ?? parameterState.runtimeError {
                    let isLoadError = loadError != nil
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(isLoadError ? "Audio bypassed — preset failed to load" : "Audio bypassed — runtime error")
                                .font(.caption).bold()
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(error, forType: .string)
                                errorCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    errorCopied = false
                                }
                            } label: {
                                Label(errorCopied ? "Copied" : "Copy", systemImage: errorCopied ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        Text(error)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .background(.yellow.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal)
                }

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

            if let meta = metadata, meta.isToggle {
                Spacer()
                Toggle("", isOn: toggleBinding)
                    .labelsHidden()
            } else if let meta = metadata, meta.isChoice, let options = meta.options {
                Spacer()
                Picker("", selection: choiceBinding(optionCount: options.count)) {
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                        Text(opt).tag(idx)
                    }
                }
                .labelsHidden()
            } else if let meta = metadata {
                Slider(value: $value, in: meta.min...meta.max)
            } else {
                Slider(value: $value, in: 0...1)
            }

            Text(formattedValue)
                .font(.caption.monospaced())
                .frame(width: 64, alignment: .trailing)
        }
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
        return ExportAUAudioUnit.formatParamValue(value, unit: meta.unit)
    }
}
