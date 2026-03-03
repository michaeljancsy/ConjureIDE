import SwiftUI

/// Toolbar for browsing, running, saving, and deleting presets.
struct PresetToolbar: View {
    @ObservedObject var presetManager: PresetManager
    @ObservedObject var aiService: AIService
    var isCompiling: Bool = false
    @Binding var selectedLanguage: ScriptLanguage
    var onSelectPreset: (Preset) -> Void
    var onRun: () -> Void
    var onSave: () -> Void
    var onSaveAs: (String) -> Void
    var onDelete: () -> Void
    var onNew: () -> Void
    var onGenerate: (String) -> Void

    @Binding var showingSaveAs: Bool
    @Binding var saveAsName: String
    @State private var showDeleteConfirm = false
    @State private var showingGenerate = false
    @State private var showingSettings = false

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
            Picker("Language", selection: $selectedLanguage) {
                Text("Python").tag(ScriptLanguage.python)
                Text("Rust").tag(ScriptLanguage.rust)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .accessibilityIdentifier("languagePicker")

            Spacer()

            // Generate with AI
            Button(action: { showingGenerate = true }) {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            .disabled(aiService.isGenerating)
            .accessibilityIdentifier("generateButton")
            .popover(isPresented: $showingGenerate) {
                GeneratePopover(
                    aiService: aiService,
                    isPresented: $showingGenerate,
                    onGenerate: onGenerate
                )
            }

            // Cancel generation (visible during streaming)
            if aiService.isGenerating {
                Button(action: { aiService.cancel() }) {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .accessibilityIdentifier("cancelGenerateButton")
            }

            // Run (compile if needed, then load into kernel)
            Button("Run") {
                onRun()
            }
            .disabled(aiService.isGenerating || isCompiling)
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

            // AI Settings
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settingsButton")
            .popover(isPresented: $showingSettings) {
                AISettingsPopover(
                    aiService: aiService,
                    onDone: { showingSettings = false }
                )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
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
