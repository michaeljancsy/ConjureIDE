import SwiftUI

/// Toolbar for browsing, running, saving, and deleting presets.
struct PresetToolbar: View {
    @ObservedObject var presetManager: PresetManager
    var onSelectPreset: (Preset) -> Void
    var onRun: () -> Void
    var onSave: () -> Void
    var onSaveAs: (String) -> Void
    var onDelete: () -> Void
    var onNew: () -> Void

    @Binding var showingSaveAs: Bool
    @Binding var saveAsName: String
    @State private var showDeleteConfirm = false

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

            Spacer()

            // Run (hot-reload into kernel)
            Button("Run") {
                onRun()
            }
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
