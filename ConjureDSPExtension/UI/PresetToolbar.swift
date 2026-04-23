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
                        .offset(y: 30)
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
    @ObservedObject var subscriptionManager: SubscriptionManager
    @ObservedObject var gitHubService: GitHubService
    @Bindable var gitCoordinator: PresetGitCoordinator
    var isCompiling: Bool = false
    var hasUnrunChanges: Bool = false
    var selectedLanguage: ScriptLanguage
    @Binding var showSpectrogram: Bool
    @Binding var showChat: Bool
    @Binding var showNewScriptDialog: Bool
    var onSelectPreset: (Preset) -> Void
    var onRun: () -> Void
    /// Overwrite-save with an optional user-supplied commit message. nil means use default.
    var onSave: (_ commitMessage: String?) -> Void
    /// Save As with an optional user-supplied commit message. nil means use default.
    var onSaveAs: (_ name: String, _ commitMessage: String?) -> Void
    var onDelete: () -> Void
    var onRename: (String) -> String?
    var onNew: (ScriptLanguage) -> Void
    var onExport: (String) -> Void
    var isExporting: Bool = false
    var containsNamTone: Bool = false
    @Binding var bypassed: Bool
    var onBypassToggle: () -> Void

    @Binding var showingSaveAs: Bool
    @Binding var saveAsName: String
    /// Binding so Cmd-S from the main view can open the same commit-message
    /// popover that's anchored to the Save button.
    @Binding var showingSaveMessage: Bool
    /// Callback invoked when a NAM tone is selected in the tone browser.
    /// The receiver is expected to splice imports and the model instantiation
    /// into the active script at language-appropriate locations.
    var onInsertTone: ((NAMToneInsertion) -> Void)?

    @State private var showDeleteConfirm = false
    @State private var showingRename = false
    @State private var renameName = ""
    @State private var renameError: String?
    @State private var showingSettings = false
    @State private var settingsTab: SettingsTab = .license

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case license = "License"
        case sync    = "Sync"
        case editor  = "Editor"
        case terminal = "Terminal"
        case about   = "About"
        var id: String { rawValue }
    }
    @State private var showingPackages = false
    @State private var packageInstallManager = PackageInstallManager()
    @State private var crateInstallManager = CrateInstallManager()
    @State private var showingTones = false
    @State private var toneClient = Tone3000Client()
    @State private var toneModelStore = ToneModelStore()
    @State private var showingExport = false
    @State private var showingPresetBrowser = false
    @State private var showingImportURL = false
    @State private var showingSync = false
    @State private var exportName = ""

    private var currentIsMutable: Bool {
        guard let current = presetManager.currentPreset else { return false }
        return current.isUser
    }

    var body: some View {
        HStack(spacing: 6) {
            // — Preset zone —
            // Preset browser button
            Button(action: { showingPresetBrowser = true }) {
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
            .buttonStyle(.borderless)
            .frame(minWidth: 100, maxWidth: 200)
            .accessibilityIdentifier("presetMenu")
            .popover(isPresented: $showingPresetBrowser) {
                PresetBrowserView(
                    presets: presetManager.presets,
                    currentPreset: presetManager.currentPreset,
                    isModified: presetManager.isModified,
                    onSelectPreset: { preset in
                        showingPresetBrowser = false
                        onSelectPreset(preset)
                    },
                    onImportURL: { showingImportURL = true },
                    onDismiss: { showingPresetBrowser = false }
                )
            }

            // Language badge (read-only)
            Text(selectedLanguage == .python ? "Python" : "Rust")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)

            Spacer()

            // — Script actions zone —
            Divider().frame(height: 28)

            // Run
            Button(action: { onRun() }) {
                VStack(alignment: .center, spacing: 1) {
                    Image(systemName: "play.fill")
                        .frame(height: 16)
                        .overlay(alignment: .topTrailing) {
                            if hasUnrunChanges {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 3, y: -3)
                            }
                        }
                    Text("Run")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(isCompiling)
            .toolbarTooltip("Run (\u{2318}R)")
            .accessibilityIdentifier("runButton")

            // Bypass
            Button(action: { bypassed.toggle(); onBypassToggle() }) {
                VStack(alignment: .center, spacing: 1) {
                    Image(systemName: bypassed ? "waveform.slash" : "waveform")
                        .frame(height: 16)
                        .foregroundColor(bypassed ? .orange : .primary)
                    Text("Bypass")
                        .font(.system(size: 9))
                        .foregroundColor(bypassed ? .orange : .secondary)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .toolbarTooltip(bypassed ? "Bypass ON — click to enable processing" : "Bypass processing (A/B compare)")
            .accessibilityIdentifier("bypassButton")

            // Save (overwrite current user preset). In alwaysPrompt mode,
            // show a small popover to collect a commit message first. In
            // alwaysTimestamp mode, fire the save immediately with a nil
            // message (the coordinator substitutes a timestamp).
            if currentIsMutable {
                Button(action: {
                    switch gitCoordinator.mode {
                    case .alwaysPrompt:
                        showingSaveMessage = true
                    case .alwaysTimestamp:
                        onSave(nil)
                    }
                }) {
                    VStack(alignment: .center, spacing: 1) {
                        Image(systemName: "square.and.arrow.down")
                            .frame(height: 16)
                        Text("Save")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(!presetManager.isModified)
                .toolbarTooltip("Save (\u{2318}S)")
                .accessibilityIdentifier("savePresetButton")
                .popover(isPresented: $showingSaveMessage) {
                    let name = presetManager.currentPreset?.name ?? ""
                    SaveMessagePopover(
                        defaultMessage: "Update \(name)",
                        onSave: { message in
                            showingSaveMessage = false
                            onSave(message)
                        },
                        onDontAskAgain: {
                            gitCoordinator.mode = .alwaysTimestamp
                            showingSaveMessage = false
                            onSave(nil)
                        },
                        onCancel: { showingSaveMessage = false }
                    )
                }
            }

            // Save As
            Button(action: {
                saveAsName = presetManager.currentPreset?.name ?? ""
                showingSaveAs = true
            }) {
                VStack(alignment: .center, spacing: 1) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .frame(height: 16)
                    Text("Save As")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .toolbarTooltip("Save As\u{2026}")
            .accessibilityIdentifier("saveAsButton")
            .popover(isPresented: $showingSaveAs) {
                SaveAsPopover(
                    name: $saveAsName,
                    existingNames: Set(presetManager.presets.filter { !$0.isFactory }.map(\.name)),
                    commitMessageMode: gitCoordinator.mode,
                    defaultCommitMessagePrefix: "Add",
                    onSave: { name, commitMessage in
                        showingSaveAs = false
                        onSaveAs(name, commitMessage)
                    },
                    onDontAskAgain: {
                        gitCoordinator.mode = .alwaysTimestamp
                    },
                    onCancel: { showingSaveAs = false }
                )
            }

            // New script
            Button(action: { showNewScriptDialog = true }) {
                VStack(alignment: .center, spacing: 1) {
                    Image(systemName: "doc.badge.plus")
                        .frame(height: 16)
                    Text("New")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
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

            // Delete and Rename (user/repo presets only)
            if currentIsMutable {
                Button(action: {
                    renameName = presetManager.currentPreset?.name ?? ""
                    renameError = nil
                    showingRename = true
                }) {
                    VStack(alignment: .center, spacing: 1) {
                        Image(systemName: "pencil")
                            .frame(height: 16)
                        Text("Rename")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .toolbarTooltip("Rename preset")
                .accessibilityIdentifier("renamePresetButton")
                .popover(isPresented: $showingRename) {
                    RenamePopover(
                        name: $renameName,
                        currentName: presetManager.currentPreset?.name ?? "",
                        existingNames: Set(presetManager.presets.filter { !$0.isFactory }.map(\.name)),
                        errorMessage: renameError,
                        onRename: { name in
                            if let error = onRename(name) {
                                renameError = error
                            } else {
                                renameError = nil
                                showingRename = false
                            }
                        },
                        onCancel: {
                            renameError = nil
                            showingRename = false
                        }
                    )
                }
                .onChange(of: presetManager.currentPreset) { _, _ in
                    if showingRename { showingRename = false }
                }

                Button(action: { showDeleteConfirm = true }) {
                    VStack(alignment: .center, spacing: 1) {
                        Image(systemName: "trash")
                            .frame(height: 16)
                        Text("Delete")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .toolbarTooltip("Delete preset")
                .accessibilityIdentifier("deletePresetButton")
                .alert("Delete Preset", isPresented: $showDeleteConfirm) {
                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Delete \"\(presetManager.currentPreset?.name ?? "")\"? This cannot be undone (but it will remain in the preset git history).")
                }
            }

            // — Panel toggles zone —
            Divider().frame(height: 28)

            // Export as standalone AU
            Button(action: {
                exportName = presetManager.currentPreset?.name ?? "My Effect"
                showingExport = true
            }) {
                VStack(alignment: .center, spacing: 1) {
                    Group {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.doc")
                        }
                    }
                    .frame(height: 16)
                    Text("Export")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(!subscriptionManager.isLicensed || isExporting || isCompiling)
            .toolbarTooltip(subscriptionManager.isLicensed ? "Export as standalone AU" : "License required to export")
            .accessibilityIdentifier("exportButton")
            .popover(isPresented: $showingExport) {
                ExportPopover(
                    exportName: $exportName,
                    language: selectedLanguage,
                    isLicensed: subscriptionManager.isLicensed,
                    containsNamTone: containsNamTone,
                    onExport: { name in
                        showingExport = false
                        onExport(name)
                    },
                    onCancel: { showingExport = false }
                )
            }

            // Git push/sync status button will be wired up in Checkpoint 4
            // when RemoteSyncSettingsView + PresetGitCoordinator are fully
            // surfaced. For now the toolbar has no sync affordance.

            // Claude Code terminal toggle
            Button(action: { showChat.toggle() }) {
                VStack(alignment: .center, spacing: 1) {
                    Image(systemName: showChat ? "terminal.fill" : "terminal")
                        .frame(height: 16)
                    Text("Terminal")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .toolbarTooltip(showChat ? "Hide Claude Code" : "Show Claude Code")
            .accessibilityIdentifier("chatToggleButton")

            // Spectrogram toggle
            Button(action: { showSpectrogram.toggle() }) {
                VStack(alignment: .center, spacing: 1) {
                    Image(systemName: showSpectrogram ? "waveform.path.ecg.rectangle" : "waveform.path.ecg")
                        .frame(height: 16)
                    Text("Spectrogram")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .toolbarTooltip(showSpectrogram ? "Hide spectrogram" : "Show spectrogram")
            .accessibilityIdentifier("spectrogramToggleButton")

            // — Status/settings zone —
            Divider().frame(height: 28)

            // Beta / Demo mode indicator — links to subscribe page
            if subscriptionManager.isBetaActive {
                Link(destination: SubscriptionSettingsView.subscribeURL) {
                    Text("BETA")
                        .font(.caption2.bold())
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.15))
                        .cornerRadius(3)
                }
                .accessibilityIdentifier("betaIndicator")
            } else if !subscriptionManager.isLicensed {
                Link(destination: SubscriptionSettingsView.subscribeURL) {
                    Text("DEMO")
                        .font(.caption2.bold())
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                }
                .accessibilityIdentifier("demoIndicator")
            }

            // Packages / Crates
            Button(action: { showingPackages = true }) {
                VStack(alignment: .center, spacing: 1) {
                    Image(systemName: "shippingbox")
                        .frame(height: 16)
                    Text("Packages")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .toolbarTooltip("Packages")
            .accessibilityIdentifier("packagesButton")
            .popover(isPresented: $showingPackages) {
                PackageManagerView(
                    installManager: packageInstallManager,
                    crateInstallManager: crateInstallManager,
                    onDone: { showingPackages = false },
                    initialLanguage: selectedLanguage == .rust
                        ? .rust : .python
                )
            }

            // Tones (NAM models from tone3000)
            Button(action: { showingTones = true }) {
                VStack(alignment: .center, spacing: 1) {
                    Image(systemName: "guitars")
                        .frame(height: 16)
                    Text("Tones")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .toolbarTooltip("Browse amp/pedal tones")
            .accessibilityIdentifier("tonesButton")
            .popover(isPresented: $showingTones) {
                ToneBrowserView(
                    client: toneClient,
                    modelStore: toneModelStore,
                    selectedLanguage: selectedLanguage,
                    onDone: { showingTones = false },
                    onInsertTone: { insertion in
                        showingTones = false
                        onInsertTone?(insertion)
                    }
                )
            }

            // Settings (License + AI)
            Button(action: { showingSettings = true }) {
                VStack(alignment: .center, spacing: 1) {
                    Image(systemName: "gearshape")
                        .frame(height: 16)
                    Text("Settings")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .toolbarTooltip("Settings")
            .accessibilityIdentifier("settingsButton")
            .popover(isPresented: $showingSettings) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $settingsTab) {
                        ForEach(SettingsTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    // Swap the tab body. No outer ScrollView / no max height —
                    // the popover sizes to the current tab's natural content.
                    // If a tab ever grows past the screen, wrap that specific
                    // tab in its own ScrollView rather than constraining here.
                    VStack(alignment: .leading, spacing: 16) {
                        switch settingsTab {
                        case .license:
                            SubscriptionSettingsView(subscriptionManager: subscriptionManager)
                        case .sync:
                            RemoteSyncSettingsView(
                                gitHubService: gitHubService,
                                gitCoordinator: gitCoordinator,
                                onDone: { showingSettings = false }
                            )
                        case .editor:
                            EditorSettingsView()
                        case .terminal:
                            TerminalSettingsView()
                        case .about:
                            ThirdPartyLicensesView()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .frame(width: 420)
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onReceive(NotificationCenter.default.publisher(for: .openLicenseSettings)) { _ in
            showingSettings = true
        }
        .popover(isPresented: $showingImportURL) {
            ImportURLPopover(
                presetManager: presetManager,
                resolver: GitHubURLResolver(),
                gitCoordinator: gitCoordinator,
                onImported: { preset in
                    showingImportURL = false
                    onSelectPreset(preset)
                },
                onCancel: { showingImportURL = false }
            )
        }
        .onAppear {
            packageInstallManager.onPackagesChanged = { onRun() }
            crateInstallManager.onCratesChanged = { onRun() }
        }
    }

}
