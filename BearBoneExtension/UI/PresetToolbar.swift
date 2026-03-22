import SwiftUI

extension Notification.Name {
    static let openLicenseSettings = Notification.Name("openLicenseSettings")
}

/// Tooltip that works through the AU ViewBridge (NSView .toolbarTooltip() / .toolTip doesn't).
/// Shows a floating label below the view after a short hover delay.
private struct ToolbarTooltip: ViewModifier {
    let text: String
    @State private var isHovering = false
    @State private var showTooltip = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if isHovering { showTooltip = true }
                    }
                } else {
                    showTooltip = false
                }
            }
            .overlay(alignment: .bottom) {
                if showTooltip {
                    Text(text)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .cornerRadius(4)
                        .shadow(radius: 2)
                        .fixedSize()
                        .offset(y: 22)
                        .zIndex(100)
                        .allowsHitTesting(false)
                }
            }
    }
}

private extension View {
    func toolbarTooltip(_ text: String) -> some View {
        modifier(ToolbarTooltip(text: text))
    }
}

/// Toolbar for browsing, running, saving, and deleting presets.
struct PresetToolbar: View {
    @ObservedObject var presetManager: PresetManager
    @ObservedObject var aiService: AIService
    @ObservedObject var licenseManager: LicenseManager
    var isCompiling: Bool = false
    var hasUnrunChanges: Bool = false
    var selectedLanguage: ScriptLanguage
    @Binding var showSpectrogram: Bool
    @Binding var showChat: Bool
    @Binding var showNewScriptDialog: Bool
    var onSelectPreset: (Preset) -> Void
    var onRun: () -> Void
    var onSave: () -> Void
    var onSaveAs: (String) -> Void
    var onDelete: () -> Void
    var onNew: (ScriptLanguage) -> Void
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
            // — Preset zone —
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

            // Language badge (read-only)
            Text(selectedLanguage == .python ? "Python" : "Rust")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)

            Spacer()

            // — Script actions zone —
            Divider().frame(height: 20)

            // Run
            Button(action: { onRun() }) {
                Image(systemName: "play.fill")
                    .overlay(alignment: .topTrailing) {
                        if hasUnrunChanges {
                            Circle()
                                .fill(.orange)
                                .frame(width: 6, height: 6)
                                .offset(x: 3, y: -3)
                        }
                    }
            }
            .buttonStyle(.borderless)
            .disabled(isCompiling)
            .toolbarTooltip("Run (\u{2318}R)")
            .accessibilityIdentifier("runButton")

            // Save (overwrite current user preset)
            if currentIsUserPreset {
                Button(action: { onSave() }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(!presetManager.isModified)
                .toolbarTooltip("Save (\u{2318}S)")
                .accessibilityIdentifier("savePresetButton")
            }

            // Save As
            Button(action: {
                saveAsName = presetManager.currentPreset?.name ?? ""
                showingSaveAs = true
            }) {
                Image(systemName: "square.and.arrow.down.on.square")
            }
            .buttonStyle(.borderless)
            .toolbarTooltip("Save As\u{2026}")
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
            Button(action: { showNewScriptDialog = true }) {
                Image(systemName: "doc.badge.plus")
            }
            .buttonStyle(.borderless)
            .toolbarTooltip("New (\u{2318}N)")
            .accessibilityIdentifier("newScriptButton")
            .popover(isPresented: $showNewScriptDialog) {
                VStack(spacing: 8) {
                    Text("New Script")
                        .font(.headline)
                    Text("Choose a language:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Button("Python") {
                            showNewScriptDialog = false
                            onNew(.python)
                        }
                        .controlSize(.large)
                        Button("Rust") {
                            showNewScriptDialog = false
                            onNew(.rust)
                        }
                        .controlSize(.large)
                    }
                }
                .padding()
            }

            // Delete (user presets only)
            if currentIsUserPreset {
                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .toolbarTooltip("Delete preset")
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

            // — Panel toggles zone —
            Divider().frame(height: 20)

            // Export as standalone AU
            Button(action: {
                exportName = presetManager.currentPreset?.name ?? "My Effect"
                showingExport = true
            }) {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.doc")
                }
            }
            .buttonStyle(.borderless)
            .disabled(!licenseManager.isLicensed || isExporting || isCompiling)
            .toolbarTooltip(licenseManager.isLicensed ? "Export as standalone AU" : "License required to export")
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
            .toolbarTooltip(showChat ? "Hide AI chat" : "Show AI chat")
            .accessibilityIdentifier("chatToggleButton")

            // Spectrogram toggle
            Button(action: { showSpectrogram.toggle() }) {
                Image(systemName: showSpectrogram ? "waveform.path.ecg.rectangle" : "waveform.path.ecg")
            }
            .buttonStyle(.borderless)
            .toolbarTooltip(showSpectrogram ? "Hide spectrogram" : "Show spectrogram")
            .accessibilityIdentifier("spectrogramToggleButton")

            // — Status/settings zone —
            Divider().frame(height: 20)

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
            .toolbarTooltip("Settings")
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
        .font(.system(size: 14))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onReceive(NotificationCenter.default.publisher(for: .openLicenseSettings)) { _ in
            showingSettings = true
        }
    }

}
