import SwiftUI

extension Notification.Name {
    static let openLicenseSettings = Notification.Name("openLicenseSettings")
}

/// Toolbar for browsing, running, saving, and deleting presets.
struct PresetToolbar: View {
    @ObservedObject var presetManager: PresetManager
    @ObservedObject var aiService: AIService
    @ObservedObject var licenseManager: LicenseManager
    var isCompiling: Bool = false
    @Binding var selectedLanguage: ScriptLanguage
    @Binding var showSpectrogram: Bool
    @Binding var showChat: Bool
    var onSelectPreset: (Preset) -> Void
    var onRun: () -> Void
    var onSave: () -> Void
    var onSaveAs: (String) -> Void
    var onDelete: () -> Void
    var onNew: () -> Void
    var onExport: (String) -> Void
    var isExporting: Bool = false

    @Binding var showingSaveAs: Bool
    @Binding var saveAsName: String
    @State private var showDeleteConfirm = false
    @State private var showingSettings = false
    @State private var showingExport = false
    @State private var exportName = ""

    private var currentIsUserPreset: Bool {
        guard let current = presetManager.currentPreset else { return false }
        return !current.isFactory
    }

    var body: some View {
        HStack(spacing: 6) {
            // Previous preset
            Button(action: selectPrevious) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(presetManager.presets.isEmpty)
            .accessibilityIdentifier("prevPresetButton")

            // Preset picker menu
            Menu {
                Section("Factory") {
                    ForEach(presetManager.presets.filter(\.isFactory)) { preset in
                        Button(action: { onSelectPreset(preset) }) {
                            if presetManager.currentPreset?.id == preset.id {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                }
                let userPresets = presetManager.presets.filter { !$0.isFactory }
                if !userPresets.isEmpty {
                    Section("User") {
                        ForEach(userPresets) { preset in
                            Button(action: { onSelectPreset(preset) }) {
                                if presetManager.currentPreset?.id == preset.id {
                                    Label(preset.name, systemImage: "checkmark")
                                } else {
                                    Text(preset.name)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(presetManager.currentPreset?.name ?? "Untitled")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if presetManager.isModified {
                        Text("*")
                            .foregroundColor(.orange)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 100, maxWidth: 200)
            .accessibilityIdentifier("presetMenu")

            // Next preset
            Button(action: selectNext) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(presetManager.presets.isEmpty)
            .accessibilityIdentifier("nextPresetButton")

            // Language selector
            Picker("", selection: $selectedLanguage) {
                Text("Python").tag(ScriptLanguage.python)
                Text("Rust").tag(ScriptLanguage.rust)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .controlSize(.small)
            .accessibilityIdentifier("languagePicker")

            Spacer()

            // Run (compile if needed, then load into kernel)
            Button("Run") {
                onRun()
            }
            .disabled(isCompiling)
            .accessibilityIdentifier("runButton")

            // Save (overwrite current user preset)
            if currentIsUserPreset {
                Button("Save") {
                    onSave()
                }
                .disabled(!presetManager.isModified)
                .accessibilityIdentifier("savePresetButton")
            }

            // Save As...
            Button("Save As\u{2026}") {
                saveAsName = presetManager.currentPreset?.name ?? ""
                showingSaveAs = true
            }
            .accessibilityIdentifier("saveAsButton")
            .popover(isPresented: $showingSaveAs) {
                SaveAsPopover(
                    name: $saveAsName,
                    existingNames: Set(presetManager.presets.filter { !$0.isFactory }.map(\.name)),
                    onSave: { name in
                        showingSaveAs = false
                        onSaveAs(name)
                    },
                    onCancel: { showingSaveAs = false }
                )
            }

            // New script
            Button("New") {
                onNew()
            }
            .accessibilityIdentifier("newScriptButton")

            // Delete (user presets only)
            if currentIsUserPreset {
                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("deletePresetButton")
                .alert("Delete Preset", isPresented: $showDeleteConfirm) {
                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Delete \"\(presetManager.currentPreset?.name ?? "")\"? This cannot be undone.")
                }
            }

            // Export as standalone AU
            Button(action: {
                exportName = presetManager.currentPreset?.name ?? "My Effect"
                showingExport = true
            }) {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .buttonStyle(.borderless)
            .disabled(!licenseManager.isLicensed || isExporting || isCompiling)
            .help(licenseManager.isLicensed ? "Export as standalone AU" : "License required to export")
            .accessibilityIdentifier("exportButton")
            .popover(isPresented: $showingExport) {
                ExportPopover(
                    exportName: $exportName,
                    language: selectedLanguage,
                    isLicensed: licenseManager.isLicensed,
                    onExport: { name in
                        showingExport = false
                        onExport(name)
                    },
                    onCancel: { showingExport = false }
                )
            }

            // Chat sidebar toggle
            Button(action: { showChat.toggle() }) {
                Image(systemName: showChat ? "bubble.left.fill" : "bubble.left")
            }
            .buttonStyle(.borderless)
            .help(showChat ? "Hide AI chat" : "Show AI chat")
            .accessibilityIdentifier("chatToggleButton")

            // Spectrogram toggle
            Button(action: { showSpectrogram.toggle() }) {
                Image(systemName: showSpectrogram ? "chart.bar.xaxis.ascending" : "chart.bar.xaxis")
            }
            .buttonStyle(.borderless)
            .help(showSpectrogram ? "Hide spectrogram" : "Show spectrogram")
            .accessibilityIdentifier("spectrogramToggleButton")

            // Demo mode indicator
            if !licenseManager.isLicensed {
                Text("DEMO")
                    .font(.caption2.bold())
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(3)
                    .accessibilityIdentifier("demoIndicator")
            }

            // Settings (License + AI)
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settingsButton")
            .popover(isPresented: $showingSettings) {
                VStack(spacing: 0) {
                    LicenseSettingsView(licenseManager: licenseManager)
                    Divider()
                    AISettingsPopover(
                        aiService: aiService,
                        onDone: { showingSettings = false }
                    )
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .controlSize(.small)
        .onReceive(NotificationCenter.default.publisher(for: .openLicenseSettings)) { _ in
            showingSettings = true
        }
    }

    private func selectPrevious() {
        let presets = presetManager.presets
        guard !presets.isEmpty else { return }
        guard let current = presetManager.currentPreset,
              let idx = presets.firstIndex(where: { $0.id == current.id }) else {
            onSelectPreset(presets.last!)
            return
        }
        let prevIdx = idx == presets.startIndex ? presets.index(before: presets.endIndex) : presets.index(before: idx)
        onSelectPreset(presets[prevIdx])
    }

    private func selectNext() {
        let presets = presetManager.presets
        guard !presets.isEmpty else { return }
        guard let current = presetManager.currentPreset,
              let idx = presets.firstIndex(where: { $0.id == current.id }) else {
            onSelectPreset(presets.first!)
            return
        }
        let nextIdx = presets.index(after: idx)
        onSelectPreset(nextIdx < presets.endIndex ? presets[nextIdx] : presets.first!)
    }
}
