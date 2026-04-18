//
//  ExportAUMainView.swift
//  ConjureDSPExportAUTemplateExtension
//

import SwiftUI

struct ExportAUMainView: View {
    @ObservedObject var parameterState: ExportParameterState
    let config: RuntimeConfig?
    /// URL to the custom UI entry HTML when the preset shipped one. Resolved
    /// by `RuntimeConfig.customUIEntryURL(in:)` and null otherwise.
    let customUIEntryURL: URL?
    /// Capture manager forwarded to the custom UI webview. Nil when the
    /// preset has no custom UI (generic slider path — no capture needed).
    let captureManager: ExportAudioCaptureManager?
    let pythonRuntimeMissing: Bool
    var loadError: String? = nil
    /// Called when layout-relevant state changes (debug pane, error visibility)
    /// so the view controller can resize the AU window via `preferredContentSize`.
    var onLayoutChange: ((_ showDebug: Bool, _ hasError: Bool) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var errorCopied = false
    @State private var showDebugPane = false

    var body: some View {
        if pythonRuntimeMissing {
            PythonRuntimeErrorView(presetName: config?.presetName)
        } else if showDebugPane {
            // Full-window debug view. Header keeps the preset name and gear
            // menu, plus an explicit "Done" button so the return path is
            // obvious. The pane itself fills all remaining space — 360pt
            // squeezed under the slider stack was unreadable.
            debugFullscreenView
                .onChange(of: showDebugPane) { _, _ in
                    notifyLayoutChange()
                }
                .onChange(of: parameterState.runtimeError) { _, _ in
                    notifyLayoutChange()
                }
        } else {
            VStack(spacing: 12) {
                ZStack {
                    Text(config?.presetName ?? "ConjureDSP Export")
                        .font(.headline)
                    HStack {
                        Spacer()
                        settingsMenu
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 12)

                Divider()

                // Custom UI if the exporter copied one in — otherwise, the
                // existing generic slider layout. Parameter state + debug
                // pane + error banner wrap both paths identically so DAW
                // automation, stats, and error reporting behave the same
                // regardless of whether a preset shipped a custom UI.
                if let entryURL = customUIEntryURL, let captureManager {
                    ExportCustomUIWebView(
                        parameterState: parameterState,
                        uiDirectoryURL: entryURL.deletingLastPathComponent(),
                        entryHTMLPath: entryURL.lastPathComponent,
                        theme: colorScheme,
                        captureManager: captureManager
                    )
                    .frame(minHeight: CGFloat(config?.ui?.height ?? 220))
                } else {
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

                // Error banner when debug is closed. (When debug is open, the
                // log already includes the error — no banner needed.)
                if let error = loadError ?? parameterState.runtimeError {
                    Divider()
                    errorBanner(error: error, isLoadError: loadError != nil)
                }

                Spacer(minLength: 0)

                Text("Made with ConjureDSP")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            .onChange(of: showDebugPane) { _, _ in
                notifyLayoutChange()
            }
            .onChange(of: parameterState.runtimeError) { _, _ in
                notifyLayoutChange()
            }
            .onAppear {
                notifyLayoutChange()
            }
        }
    }

    @ViewBuilder
    private var settingsMenu: some View {
        Menu {
            Button(showDebugPane ? "Hide Debug Log" : "Show Debug Log") {
                showDebugPane.toggle()
            }
            Divider()
            Button("Copy Log") {
                let text = parameterState.debugLog.formattedForCopy()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Button("Clear Log") {
                parameterState.debugLog.clear()
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.body)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var debugFullscreenView: some View {
        VStack(spacing: 12) {
            ZStack {
                Text(config?.presetName ?? "ConjureDSP Export")
                    .font(.headline)
                HStack {
                    Button("Done") { showDebugPane = false }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.escape, modifiers: [])
                        .accessibilityIdentifier("debugDoneButton")
                    Spacer()
                    settingsMenu
                }
                .padding(.horizontal, 12)
            }
            .padding(.top, 12)

            Divider()

            DebugPaneView(
                debugLog: parameterState.debugLog,
                stats: parameterState.statsSnapshot,
                info: parameterState.pluginInfo
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }
}

extension ExportAUMainView {
    private var hasError: Bool {
        loadError != nil || parameterState.runtimeError != nil
    }

    private func notifyLayoutChange() {
        onLayoutChange?(showDebugPane, hasError && !showDebugPane)
    }

    @ViewBuilder
    func errorBanner(error: String, isLoadError: Bool) -> some View {
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
            ScrollView {
                Text(error)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(.yellow.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
    }
}

/// Custom slider with a styled track and thumb, matching the main extension's DSPSlider.
private struct DSPSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    var onDoubleTap: (() -> Void)? = nil

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
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumbDiameter / 2)

                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.accentColor)
                    .frame(width: max(thumbDiameter / 2, thumbX), height: trackHeight)
                    .padding(.leading, thumbDiameter / 2)
                    .clipped()

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

struct ExportParamSliderRow: View {
    let label: String
    @Binding var value: Float
    let metadata: ExportParamMetadata?

    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var fieldFocused: Bool

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

    private func commitEdit(exitOnError: Bool = true) {
        guard let parsed = Float(editText) else {
            if exitOnError {
                isEditing = false
            } else {
                fieldFocused = true
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
    /// params so dragging the slider feels detented.
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
        return ExportAUAudioUnit.formatParamValue(value, unit: meta.unit, isInteger: meta.isInteger)
    }
}
