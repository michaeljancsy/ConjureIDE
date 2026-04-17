//
//  ConjureDSPExtensionMainView.swift
//  ConjureDSPExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import Combine
import SwiftUI

struct ScriptSaveResult {
    let success: Bool
    let error: String?
    let warning: String?
    let processTimeMs: Double?
    let budgetMs: Double?

    init(success: Bool, error: String? = nil, warning: String? = nil, processTimeMs: Double? = nil, budgetMs: Double? = nil) {
        self.success = success
        self.error = error
        self.warning = warning
        self.processTimeMs = processTimeMs
        self.budgetMs = budgetMs
    }
}

struct ConjureDSPExtensionMainView: View {
    var buildID: Int
    var defaultScriptSource: String
    var defaultLanguage: ScriptLanguage = .python
    var extensionBundle: Bundle
    var scriptSourcePublisher: AnyPublisher<ConjureDSPExtensionAudioUnit.ScriptSourceChange, Never>?
    // These are NOT @ObservedObject because this view never reads their
    // @Published properties in its body — it only passes them to child views
    // or uses them in action callbacks. Child views (StatusBarView,
    // PresetToolbar, etc.) have their own @ObservedObject declarations.
    // Observing them here would re-evaluate this entire body on every
    // publish (processProfiler fires 4x/sec, which caused ~12MB/min growth).
    var presetManager: PresetManager
    var captureManager: AudioCaptureManager
    var processProfiler: ProcessProfiler
    var memoryMonitor: MemoryMonitor
    var parameterState: ParameterState
    // subscriptionManager MUST be @ObservedObject — the demo expired overlay
    // reads isLicensed and demoSecondsRemaining directly in this view's body.
    @ObservedObject var subscriptionManager: SubscriptionManager
    var gitHubService: GitHubService
    @Bindable var gitCoordinator: PresetGitCoordinator
    var onRun: (String) async -> ScriptSaveResult
    var onSelectPreset: (Preset) async -> ScriptSaveResult
    /// commitMessage is optional — nil means "use the coordinator's default"
    var onSavePreset: (_ source: String, _ language: ScriptLanguage, _ commitMessage: String?) -> ScriptSaveResult
    var onSaveAsPreset: (_ name: String, _ source: String, _ language: ScriptLanguage, _ commitMessage: String?, _ includeCustomUI: Bool) -> ScriptSaveResult
    var onDeletePreset: () -> Void
    var onRenamePreset: (String) -> String?
    var onNew: (ScriptLanguage) -> ScriptSaveResult
    var onExport: (String) async -> ExportResult
    var defaultBenchmark: (processTimeMs: Double, budgetMs: Double)?
    var appGroupContainerURL: URL?
    var instanceID: String = ""
    var isBypassed: () -> Bool = { false }
    var setBypass: (Bool) -> Void = { _ in }

    @State private var bypassed: Bool = false
    @State private var scriptSource: String = ""
    @State private var mcpFlashToken: UUID? = nil
    @State private var selectedLanguage: ScriptLanguage = .python
    @State private var errorMessage: String?
    @State private var warningMessage: String?
    @State private var editorMarkers: [MonacoEditorView.Marker] = []
    @State private var showingSaveAs = false
    @State private var showingSaveMessage = false
    @State private var saveAsName = ""
    @State private var lastBenchmark: (processTimeMs: Double, budgetMs: Double)?
    @State private var showNewScriptDialog: Bool = false
    @State private var isCompiling: Bool = false
    @State private var lastRunSource: String = ""
    @State private var showSpectrogram: Bool = false
    @State private var showChat: Bool = false
    @State private var terminalHasBeenOpened: Bool = false
    @State private var showAIPromptTab: Bool = false
    @State private var chatWidth: CGFloat = 280
    @State private var isExporting: Bool = false
    @State private var exportAlertMessage: String?
    @State private var showExportAlert: Bool = false
    @State private var showDaemonRequiredAlert: Bool = false
    @State private var spectrogramWidth: CGFloat = 250
    @State private var spectrogramFrequencyScale: FrequencyScale = .log
    @State private var spectrogramFFTSizeIndex: Int = 2 // default: 2048
    @State private var spectrogramShowNoteNames: Bool = false
    @StateObject private var daemonChecker = DaemonStatusChecker()
    /// Per-bundle "show custom UI" preference. Drives the toggle in the UI
    /// area whenever the active bundle ships an HTML/JS UI, and persists
    /// across sessions so users don't have to re-flip the switch.
    @StateObject private var customUIPreference = CustomUIPreference()
    /// File currently open in the Monaco editor. Nil means the entry
    /// script (preserves pre-multi-file behavior where Monaco always
    /// bound to `$scriptSource`). Anything else is a manifest or UI
    /// asset — those edits write straight to disk and bypass the
    /// DSP Run/compile pipeline.
    @State private var editingBundleFile: BundleFileEntry? = nil
    /// Buffer backing the editor when `editingBundleFile` is non-nil.
    /// Kept separate from `scriptSource` so the Run button still maps
    /// to the DSP script, never to whatever UI file is currently open.
    @State private var altFileSource: String = ""
    /// Debounced save task for non-script files. Cancelled and
    /// rescheduled on every keystroke so we don't fsync on each
    /// character.
    @State private var altFileSaveTask: Task<Void, Never>? = nil
    /// Debounce flag for "+ Add Custom UI" — disables the button while the
    /// scaffold is being written + committed so a double-click doesn't
    /// produce two commits.
    @State private var isAddingCustomUI: Bool = false
    /// Set on each successful debounced alt-file write so the file picker
    /// bar can briefly flash a "Saved to disk" label. Disk-write feedback,
    /// NOT commit feedback — commit is a separate, explicit action.
    @State private var lastDiskSaveAt: Date? = nil
    /// Whether the bundle-file sidebar is visible. Defaults to collapsed so
    /// DSP-only authors who never touch `ui/` don't lose real estate; the
    /// toolbar's Files button + ⇧⌘E flip it open.
    @AppStorage("bundleFileBrowser.shown") private var showFileBrowser: Bool = false
    /// Width of the bundle-file sidebar when visible. Persisted so resizes
    /// stick across sessions.
    @AppStorage("bundleFileBrowser.width") private var fileBrowserWidth: Double = 180
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("editorTheme") private var selectedTheme: String = "conjuredsp"

    /// Resolved Monaco theme ID based on user preference and system appearance.
    private var resolvedTheme: String {
        if selectedTheme == "auto" {
            return colorScheme == .dark ? "vs-dark" : "vs"
        }
        return selectedTheme
    }

    private static let buildIDFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private static func formatBuildID(_ epochSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        return buildIDFormatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Preset toolbar
            PresetToolbar(
                presetManager: presetManager,
                subscriptionManager: subscriptionManager,
                gitHubService: gitHubService,
                gitCoordinator: gitCoordinator,
                isCompiling: isCompiling,
                hasUnrunChanges: scriptSource != lastRunSource,
                selectedLanguage: selectedLanguage,
                showSpectrogram: $showSpectrogram,
                showChat: $showChat,
                showNewScriptDialog: $showNewScriptDialog,
                showFileBrowser: $showFileBrowser,
                onSelectPreset: { preset in
                    Task {
                        isCompiling = true
                        selectedLanguage = preset.language
                        let result = await onSelectPreset(preset)
                        isCompiling = false
                        if result.success { lastRunSource = scriptSource }
                        handleResult(result)
                    }
                },
                onRun: {
                    Task {
                        isCompiling = true
                        let result = await onRun(scriptSource)
                        isCompiling = false
                        if result.success { lastRunSource = scriptSource }
                        handleResult(result)
                    }
                },
                onSave: { commitMessage in
                    let result = onSavePreset(scriptSource, selectedLanguage, commitMessage)
                    handleResult(result)
                },
                onSaveAs: { name, commitMessage, includeCustomUI in
                    let result = onSaveAsPreset(name, scriptSource, selectedLanguage, commitMessage, includeCustomUI)
                    handleResult(result)
                },
                onDelete: {
                    onDeletePreset()
                },
                onRename: { name in
                    return onRenamePreset(name)
                },
                onNew: { language in
                    selectedLanguage = language
                    let result = onNew(language)
                    handleResult(result)
                    if language == .rust && result.success {
                        handleCmdR()
                    }
                },
                onExport: { name in
                    guard daemonChecker.isDaemonAvailable else {
                        showDaemonRequiredAlert = true
                        return
                    }
                    Task {
                        isExporting = true
                        let result = await onExport(name)
                        isExporting = false
                        switch result {
                        case .success(let message):
                            exportAlertMessage = message
                            showExportAlert = true
                        case .error(let message):
                            exportAlertMessage = message
                            showExportAlert = true
                        default:
                            break
                        }
                    }
                },
                isExporting: isExporting,
                containsNamTone: ExportManager.containsNamReference(
                    source: scriptSource,
                    language: selectedLanguage
                ),
                bypassed: $bypassed,
                onBypassToggle: { setBypass(bypassed) },
                showingSaveAs: $showingSaveAs,
                saveAsName: $saveAsName,
                showingSaveMessage: $showingSaveMessage,
                onInsertTone: { insertion in
                    Analytics.track(.namToneInsert, properties: [
                        "tone_title": insertion.title,
                        "language": selectedLanguage.rawValue,
                    ])
                    scriptSource = insertNAMTone(
                        into: scriptSource,
                        insertion: insertion,
                        language: selectedLanguage
                    )
                }
            )

            Divider()

            // UI area: the custom HTML/JS UI (when a bundle ships one and the
            // toggle is set to it) or the generated slider panel. The toggle
            // bar above advertises both modes and — for user bundles without
            // a custom UI yet — surfaces the "+ Add Custom UI" CTA so adding
            // one is a single click instead of a hidden filesystem dance.
            let activeBundle = presetManager.currentBundle
            let hasCustom = activeBundle?.hasCustomUI ?? false
            let useCustom = hasCustom && customUIPreference.showCustomUI

            VStack(spacing: 0) {
                // Bar is always visible when a bundle is loaded (factory or
                // user). Without a bundle we skip it entirely — there's
                // nothing meaningful to toggle or customize.
                if activeBundle != nil {
                    customUIToggleBar(showingCustom: useCustom)
                }

                if useCustom, let bundle = activeBundle {
                    CustomUIWebView(
                        parameterState: parameterState,
                        bundle: bundle,
                        theme: colorScheme,
                        captureManager: captureManager
                    )
                    .frame(minHeight: CGFloat(bundle.manifest.ui?.height ?? 220))
                    .id(bundle.uiIndexURL)
                } else {
                    ParameterSlidersView(parameterState: parameterState)
                }
            }

            Divider()

            ZStack {
            HStack(spacing: 0) {
            // Terminal panel — rendered lazily on first open, then kept alive
            // to avoid WKWebView teardown choppiness.
            if terminalHasBeenOpened {
                Group {
                    VStack(spacing: 0) {
                        // Tab switcher header
                        HStack(spacing: 0) {
                            chatTabButton(label: "Terminal", isSelected: !showAIPromptTab) {
                                showAIPromptTab = false
                            }
                            chatTabButton(label: "AI Prompt", isSelected: showAIPromptTab) {
                                showAIPromptTab = true
                            }
                        }
                        .frame(height: 28)
                        .clipped()
                        .background(colorScheme == .dark
                            ? Color(white: 0.10)
                            : Color(nsColor: .windowBackgroundColor))

                        Divider()

                        // Keep all pane content alive to avoid WKWebView teardown on tab switch.
                        // Use opacity/allowsHitTesting/accessibilityHidden to show/hide without destroying the views.
                        ZStack {
                            AIPromptHelperView(
                                currentScript: scriptSource,
                                currentLanguage: selectedLanguage,
                                colorScheme: colorScheme
                            )
                            .opacity(showAIPromptTab ? 1 : 0)
                            .allowsHitTesting(showAIPromptTab)
                            .accessibilityHidden(!showAIPromptTab)

                            if daemonChecker.isDaemonAvailable {
                                TerminalView(colorScheme: colorScheme, appGroupContainerURL: appGroupContainerURL, instanceID: instanceID)
                                    .accessibilityIdentifier("terminalPanel")
                                    .opacity(showAIPromptTab ? 0 : 1)
                                    .allowsHitTesting(!showAIPromptTab)
                                    .accessibilityHidden(showAIPromptTab)
                            } else {
                                DaemonLaunchPromptView(colorScheme: colorScheme)
                                    .opacity(showAIPromptTab ? 0 : 1)
                                    .allowsHitTesting(!showAIPromptTab)
                                    .accessibilityHidden(showAIPromptTab)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(colorScheme == .dark
                        ? Color(white: 0.12)
                        : Color(nsColor: .controlBackgroundColor))
                }
                .frame(width: showChat ? chatWidth : 0)
                .clipped()
                .accessibilityHidden(!showChat)

                // Resizable divider between terminal and editor
                Rectangle()
                    .fill(Color.secondary.opacity(showChat ? 0.2 : 0))
                    .frame(width: showChat ? 4 : 0)
                    .contentShape(Rectangle().inset(by: -4))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                chatWidth = max(200, min(450, chatWidth + value.translation.width))
                            }
                    )
                    .onHover { hovering in
                        if hovering && showChat {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            }

            // File browser sidebar — collapsed by default; the toolbar's
            // Files button + ⇧⌘E toggle it. When open, sits to the left
            // of the Monaco editor panel and resizes via its trailing
            // divider (same pattern as the spectrogram).
            if showFileBrowser, let bundle = presetManager.currentBundle {
                BundleFileBrowser(
                    bundle: bundle,
                    isEditable: isCurrentBundleEditable,
                    selectedRelativePath: editingBundleFile?.relativePath
                        ?? bundle.manifest.entry,
                    onOpen: { node in openBundleFileNode(node, bundle: bundle) },
                    onCreateFile: { parent, name, template in
                        createBundleFile(parent: parent, name: name, template: template, bundle: bundle)
                    },
                    onCreateFolder: { parent, name in
                        createBundleFolder(parent: parent, name: name, bundle: bundle)
                    },
                    onRename: { node, newName in
                        renameBundleEntry(node: node, newName: newName, bundle: bundle)
                    },
                    onDelete: { node in
                        deleteBundleEntry(node: node, bundle: bundle)
                    },
                    onDuplicate: { node in
                        duplicateBundleEntry(node: node, bundle: bundle)
                    },
                    onDuplicateBundleAndEdit: { node in
                        duplicateFactoryBundleAndEdit(sourceNode: node, factoryBundle: bundle)
                    }
                )
                .frame(width: fileBrowserWidth)

                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 4)
                    .contentShape(Rectangle().inset(by: -4))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                fileBrowserWidth = max(120, min(360, fileBrowserWidth + value.translation.width))
                            }
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            }

            VStack(spacing: 0) {
                // File picker — present only when the active preset is
                // a bundle with more than one editable file. Factory
                // bundles render the picker read-only (no writes allowed
                // into the app bundle's Resources). Users can still
                // browse every file's contents, just not modify them.
                if let bundle = presetManager.currentBundle {
                    bundleFilePickerBar(bundle: bundle)
                }

                bundleEditor(editable: isCurrentBundleEditable)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Paint the container with the system text-background color
                // so the transparent WKWebView has something matching the
                // current theme to show during Monaco's ~100ms boot. Without
                // this, file-switches flash white (HTML default) before the
                // theme JS applies, producing a visible flicker in dark mode.
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color.secondary.opacity(0.3), width: 1)
                .padding(.horizontal)
                .padding(.top, 8)

                // Persistent status bar
                StatusBarView(
                    isCompiling: isCompiling,
                    errorMessage: errorMessage,
                    warningMessage: warningMessage,
                    processProfiler: processProfiler,
                    memoryMonitor: memoryMonitor,
                    lastBenchmark: lastBenchmark,
                    buildIDFormatted: buildID != 0 ? Self.formatBuildID(buildID) : nil,
                    onCopyError: {
                        if let err = errorMessage {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(err, forType: .string)
                        }
                    }
                )
            }
            .padding(.bottom, 4)

            // Spectrogram side panel (collapsible, slides from right)
            if showSpectrogram {
                // Resizable divider
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 4)
                    .contentShape(Rectangle().inset(by: -4))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                spectrogramWidth = max(150, min(500, spectrogramWidth - value.translation.width))
                            }
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }

                SpectrogramSidePanel(
                    captureManager: captureManager,
                    frequencyScale: $spectrogramFrequencyScale,
                    fftSizeIndex: $spectrogramFFTSizeIndex,
                    showNoteNames: $spectrogramShowNoteNames
                )
                .frame(width: spectrogramWidth)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            } // HStack
            .animation(.easeOut(duration: 0.15), value: showChat)
            .animation(.easeOut(duration: 0.15), value: showSpectrogram)

            // Demo expired overlay
            if !subscriptionManager.isLicensed && subscriptionManager.demoSecondsRemaining <= 0 {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)

                    Text("Demo Expired")
                        .font(.title2.bold())
                        .foregroundColor(.white)

                    Text("Audio output is silenced.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))

                    VStack(spacing: 10) {
                        Button {
                            subscriptionManager.restartDemo()
                        } label: {
                            Text("Restart Demo")
                                .frame(minWidth: 160)
                        }
                        .controlSize(.large)
                        .accessibilityIdentifier("restartDemoButton")

                        Link(destination: SubscriptionSettingsView.subscribeURL) {
                            Text("Subscribe")
                                .frame(minWidth: 160)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("subscribeLinkOverlay")

                        Button {
                            showingSaveAs = false // dismiss any other popover
                            // Open settings by triggering the toolbar gear button
                            NotificationCenter.default.post(name: .openLicenseSettings, object: nil)
                        } label: {
                            Text("Enter License Key")
                                .frame(minWidth: 160)
                        }
                        .controlSize(.large)
                        .accessibilityIdentifier("enterLicenseKeyButton")
                    }
                    .padding(.top, 4)
                }
                .padding(32)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(radius: 20)
                )
                .accessibilityIdentifier("demoExpiredOverlay")
            }
            } // ZStack
        }
        .alert("Export", isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage ?? "")
        }
        .sheet(isPresented: $showDaemonRequiredAlert) {
            DaemonRequiredAlertView(colorScheme: colorScheme) {
                showDaemonRequiredAlert = false
            }
        }
        .onChange(of: showChat) { _, newValue in
            if newValue {
                terminalHasBeenOpened = true
            }
            Analytics.track(.terminalToggle, properties: ["opened": newValue])
        }
        .onChange(of: showSpectrogram) { _, newValue in
            captureManager.setConsumer(id: "spectrogram", active: newValue)
            Analytics.track(.spectrogramToggle, properties: ["opened": newValue])
        }
        .onChange(of: presetManager.currentBundle?.name) { _, newName in
            // Bind the toggle's persisted preference to whatever bundle
            // is currently loaded. Switching presets re-reads the stored
            // choice for the new bundle so users see their last
            // selection for THIS preset, not the previous one's.
            customUIPreference.bundleKey = newName
            // Reset the bundle file picker to the entry script when the
            // preset changes — keeping an old manifest.json or
            // ui/index.html selected into an unrelated bundle would
            // just be confusing.
            altFileSaveTask?.cancel()
            altFileSaveTask = nil
            editingBundleFile = nil
        }
        .onAppear {
            customUIPreference.bundleKey = presetManager.currentBundle?.name
            scriptSource = defaultScriptSource
            lastRunSource = defaultScriptSource
            selectedLanguage = defaultLanguage
            if let bench = defaultBenchmark {
                lastBenchmark = bench
            }
            bypassed = isBypassed()
            daemonChecker.startChecking(instanceID: instanceID, appGroupContainerURL: appGroupContainerURL)

            // Listen for export finalization results from the daemon
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.MichaelJancsy.ConjureDSP.exportFinalized"),
                object: nil,
                queue: .main
            ) { notification in
                guard let userInfo = notification.userInfo,
                      let name = userInfo["name"] as? String,
                      let success = userInfo["success"] as? String else { return }
                if success == "true" {
                    exportAlertMessage = "Installed \"\(name)\". Launch the app once to register, then find it in your DAW."
                } else {
                    let error = userInfo["error"] as? String ?? "Unknown error"
                    exportAlertMessage = "Failed to install \"\(name)\": \(error)"
                }
                showExportAlert = true
            }
        }
        .onReceive(scriptSourcePublisher ?? Empty().eraseToAnyPublisher()) { change in
            scriptSource = change.source
            lastRunSource = change.source
            selectedLanguage = ScriptLanguage.detect(from: change.source)
            if change.origin == .mcp {
                mcpFlashToken = UUID()
            }
            // Clear error — this fires after successful compile (preset select, AI fix, fullState restore).
            // warningMessage is NOT cleared here: handleResult manages it, and clearing here
            // would race with handleResult during preset selection, making warnings invisible.
            errorMessage = nil
            editorMarkers = []
            if let processTimeMs = change.processTimeMs, let budgetMs = change.budgetMs {
                lastBenchmark = (processTimeMs, budgetMs)
            }
        }
        .onChange(of: scriptSource) { _, newValue in
            presetManager.scriptDidChange(to: newValue)
        }
        .background(
            Group {
                Button(action: handleCmdS) { EmptyView() }
                    .keyboardShortcut("s", modifiers: .command)
                Button(action: handleCmdR) { EmptyView() }
                    .keyboardShortcut("r", modifiers: .command)
                Button(action: handleCmdN) { EmptyView() }
                    .keyboardShortcut("n", modifiers: .command)
                Button(action: handleShiftCmdE) { EmptyView() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        )
    }

    /// Whether the Save button would be available (user preset, modified).
    private var canSave: Bool {
        guard let current = presetManager.currentPreset else { return false }
        return !current.isFactory && presetManager.isModified
    }

    /// Whether the current bundle lives in a user-writable location. User
    /// bundles live on disk under the App Group's `Presets/` git repo and
    /// can be edited in place. Factory bundles live inside the extension's
    /// Resources, which are read-only under the hardened runtime — the
    /// editor is shown but can't save.
    private var isCurrentBundleEditable: Bool {
        guard let preset = presetManager.currentPreset else { return true }
        switch preset.source {
        case .factory: return false
        default: return true
        }
    }

    /// Segmented-ish picker above the Monaco editor listing every text file
    /// in the active bundle. Switching the selection swaps the editor's
    /// buffer (and Monaco language mode) without tearing down the webview.
    @ViewBuilder
    private func bundleFilePickerBar(bundle: PresetBundle) -> some View {
        let entries = BundleFilePickerEntries.entries(for: bundle)
        // Don't bother rendering the picker for bundles that only contain
        // the entry script — the old pre-bundle behavior.
        if entries.count > 1 {
            HStack(spacing: 4) {
                Text("Edit:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: bundleFilePickerBinding(for: bundle, entries: entries)) {
                    ForEach(entries) { entry in
                        Text(entry.relativePath).tag(entry.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("bundleFilePicker")

                if !isCurrentBundleEditable {
                    Image(systemName: "lock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Factory preset files are read-only. Save As to create an editable copy.")
                }

                // Brief "Saved to disk" flash after each debounced write.
                // Intentionally distinct from "Saved" (commit) — commits
                // happen when the user hits Save / ⌘S / Run, not on every
                // keystroke. We show this here so authors get feedback that
                // their hot-reload write actually landed.
                if let at = lastDiskSaveAt, Date().timeIntervalSince(at) < 1.2 {
                    Text("Saved to disk")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                        .accessibilityIdentifier("diskSaveFlash")
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .animation(.easeInOut(duration: 0.25), value: lastDiskSaveAt)
            .task(id: lastDiskSaveAt) {
                // Schedule the opacity transition's second half. The flash
                // should vanish ~1s after the write even if the user stops
                // typing — otherwise the label persists until the next edit.
                guard lastDiskSaveAt != nil else { return }
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                // Re-check — if a newer write fired during the sleep, the
                // task is cancelled and a fresh one replaces it.
                if !Task.isCancelled {
                    lastDiskSaveAt = nil
                }
            }
        }
    }

    /// Binding that maps the picker's selected entry id to/from
    /// `editingBundleFile`. Writing through this binding loads the file's
    /// content into `altFileSource` (or restores `scriptSource` for the
    /// entry script). Reading returns the current selection's id.
    private func bundleFilePickerBinding(
        for bundle: PresetBundle, entries: [BundleFileEntry]
    ) -> Binding<String> {
        Binding<String>(
            get: { editingBundleFile?.id ?? entries.first?.id ?? "" },
            set: { newID in
                guard let next = entries.first(where: { $0.id == newID }) else { return }
                switchEditingFile(to: next, in: bundle)
            }
        )
    }

    /// Load `next`'s content into the editor. For the entry script we
    /// route back through `scriptSource` so the Run button stays
    /// meaningful; for everything else we load into `altFileSource` and
    /// let `onChange` debounce writes back to disk.
    private func switchEditingFile(to next: BundleFileEntry, in bundle: PresetBundle) {
        // Cancel any in-flight save from a previous alt file so its
        // stale content doesn't clobber the file we're about to open.
        altFileSaveTask?.cancel()
        altFileSaveTask = nil

        if next.kind == .entryScript {
            editingBundleFile = nil
            if let source = try? String(contentsOf: bundle.entryScriptURL, encoding: .utf8) {
                scriptSource = source
                lastRunSource = source
            }
        } else {
            editingBundleFile = next
            altFileSource = (try? String(contentsOf: next.url, encoding: .utf8)) ?? ""
        }
    }

    /// Monaco editor. A single WKWebView for the life of the main view —
    /// switching bundle files routes through `bridge.setContent` /
    /// `bridge.setLanguage` inside MonacoEditorView's updateNSView, which
    /// swaps the buffer in the existing Monaco instance instead of
    /// re-booting a fresh webview.
    ///
    /// Before this, `.id("bundleFile:\(alt.id)")` forced a full webview
    /// teardown + re-init on every click — Monaco took ~100–500ms to
    /// reload from disk and the transparent webview flashed while it
    /// booted. Reusing the instance is both faster and flicker-free.
    @ViewBuilder
    private func bundleEditor(editable: Bool) -> some View {
        MonacoEditorView(
            text: unifiedEditorBinding,
            theme: resolvedTheme,
            language: selectedLanguage,
            languageIDOverride: editingBundleFile?.monacoLanguageID,
            isEditable: editable,
            // Markers + the MCP flash animation only make sense for the
            // DSP entry script — on a ui/** file or manifest.json those
            // decorations would be meaningless.
            markers: editingBundleFile == nil ? editorMarkers : [],
            snippetToInsert: .constant(nil),
            flashToken: editingBundleFile == nil ? mcpFlashToken : nil
        )
    }

    /// Single binding that routes read/write to whichever file is currently
    /// open in the editor. The entry script uses `scriptSource` (so the Run
    /// button keeps meaning); every other bundle file uses `altFileSource`
    /// plus the debounced disk-write path.
    private var unifiedEditorBinding: Binding<String> {
        Binding<String>(
            get: { editingBundleFile != nil ? altFileSource : scriptSource },
            set: { newValue in
                if editingBundleFile != nil {
                    altFileSource = newValue
                    scheduleAltFileSave()
                } else {
                    scriptSource = newValue
                }
            }
        )
    }

    private func scheduleAltFileSave() {
        altFileSaveTask?.cancel()
        guard isCurrentBundleEditable, let file = editingBundleFile else { return }
        let url = file.url
        let content = altFileSource
        let kind = file.kind
        altFileSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "Could not save \(file.relativePath): \(error.localizedDescription)"
                return
            }
            // Record the write so the Save button lights up even when
            // only ui/** or manifest.json has changed (entry-script
            // modification already flips presetManager.isModified).
            presetManager.noteDirtyFile(url)
            lastDiskSaveAt = Date()
            // Manifest edits change which files count as UI etc., so the
            // preset model needs a refresh. Cheap — just re-scans the
            // active bundles on disk.
            if kind == .manifest {
                presetManager.refreshPresets()
            }
        }
    }

    /// Row that sits above the parameter panel whenever a preset bundle is
    /// loaded. Doubles as a UI-mode picker *and* the discovery surface for
    /// custom HTML/JS UIs: user bundles that don't have one yet get a
    /// `+ Add Custom UI` button in the same slot where the toggle would
    /// normally live, so adding one is a single click.
    ///
    /// States (driven by `currentBundle` + `isCurrentBundleEditable`):
    ///   - User bundle, no custom UI → label "Sliders" + `[ + Add Custom UI ]`
    ///   - User bundle, has custom UI → segmented toggle (Custom UI ↔ Sliders)
    ///   - Factory bundle, no custom UI → label "Sliders" only (branch
    ///     via the toolbar's Save As)
    ///   - Factory bundle, has custom UI → segmented toggle (read-only preview)
    @ViewBuilder
    private func customUIToggleBar(showingCustom: Bool) -> some View {
        let hasCustom = presetManager.currentBundle?.hasCustomUI ?? false
        let editable = isCurrentBundleEditable

        HStack(spacing: 6) {
            Spacer()
            Image(systemName: showingCustom ? "paintpalette" : "slider.horizontal.3")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(showingCustom ? "Custom UI" : "Sliders")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasCustom {
                // Segmented toggle — same binding as before, just with a
                // label that reflects the persisted choice. Factory bundles
                // get the toggle too so users can preview the sliders
                // version of a factory preset without forking it.
                Toggle("", isOn: $customUIPreference.showCustomUI)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Switch between the preset's custom HTML/JS UI and the slider layout.")
                    .accessibilityIdentifier("customUIToggle")
            } else if editable {
                // User bundle without a UI yet. The CTA replaces the toggle
                // — clicking drops a starter `ui/index.html` into the
                // bundle, commits it, and the bar re-renders as a toggle.
                Button(action: { addCustomUIToCurrentBundle() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus.circle")
                            .font(.caption2)
                        Text("Add Custom UI")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isAddingCustomUI)
                .help("Drop a starter ui/index.html into this preset. You can edit it inside ConjureDSP or in any external editor.")
                .accessibilityIdentifier("addCustomUIButton")
            }
            // Factory bundle without a UI → label only, no CTA. Users branch
            // via the toolbar's Save As (same as they always have).
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// Drop a starter `ui/index.html` into the current user bundle and
    /// commit it via `PresetGitCoordinator` so the new file lands in
    /// `git log` like any other preset edit. Reload + refresh happen via
    /// `refreshPresets()` inside the manager.
    private func addCustomUIToCurrentBundle() {
        guard !isAddingCustomUI,
              let bundle = presetManager.currentBundle,
              isCurrentBundleEditable else { return }

        isAddingCustomUI = true
        let scaffoldResult: Result<URL, Error>
        do {
            let url = try presetManager.scaffoldCustomUI(for: bundle)
            scaffoldResult = .success(url)
        } catch {
            scaffoldResult = .failure(error)
        }

        switch scaffoldResult {
        case .failure(let err):
            errorMessage = "Could not add custom UI: \(err.localizedDescription)"
            isAddingCustomUI = false
        case .success(let indexURL):
            // Flip the toggle to show the fresh UI immediately — no point
            // landing on "Sliders" right after the user tapped "Add Custom
            // UI." The preference is keyed on the bundle name, which just
            // got re-loaded by refreshPresets().
            customUIPreference.bundleKey = presetManager.currentBundle?.name
            customUIPreference.showCustomUI = true

            // Commit the whole bundle root, not just ui/index.html — the
            // manifest also changed (scaffoldCustomUI writes the `ui` block
            // if it was missing), and committing the parent directory makes
            // sure both files land in the same commit.
            let bundleRoot = bundle.rootURL
            Task { @MainActor in
                let result = await gitCoordinator.recordSave(
                    paths: [bundleRoot],
                    message: "Add custom UI scaffold"
                )
                isAddingCustomUI = false
                if case .failure(let err) = result {
                    errorMessage = "Custom UI scaffolded but commit failed: \(err.localizedDescription)"
                }
                _ = indexURL // silence unused warning; URL is useful for tests
            }
        }
    }

    /// True when the current preset is user-writable (i.e. Cmd-S should
    /// save-in-place, not open Save As, regardless of modified state).
    private var hasMutablePreset: Bool {
        guard let current = presetManager.currentPreset else { return false }
        return !current.isFactory
    }

    private func handleCmdS() {
        // If a user preset is loaded, Cmd-S saves in place. Falling through to
        // Save As on an already-saved preset would be surprising.
        if hasMutablePreset {
            // Respect the commit-message preference. In alwaysPrompt mode,
            // open the same popover that's anchored to the toolbar Save
            // button; in alwaysTimestamp mode, save immediately with nil
            // (the coordinator substitutes a timestamp).
            switch gitCoordinator.mode {
            case .alwaysPrompt:
                showingSaveMessage = true
            case .alwaysTimestamp:
                let result = onSavePreset(scriptSource, selectedLanguage, nil)
                handleResult(result)
            }
        } else {
            // Factory preset (or nothing) loaded — the only meaningful action
            // is to create a new user preset.
            saveAsName = presetManager.currentPreset?.name ?? ""
            showingSaveAs = true
        }
    }

    private func handleSaveAs() {
        saveAsName = presetManager.currentPreset?.name ?? ""
        showingSaveAs = true
    }

    private func handleCmdR() {
        guard !isCompiling else { return }
        Task {
            isCompiling = true
            let result = await onRun(scriptSource)
            isCompiling = false
            if result.success { lastRunSource = scriptSource }
            handleResult(result)
        }
    }

    private func handleCmdN() {
        showNewScriptDialog = true
    }

    /// ⇧⌘E toggles the file sidebar.
    private func handleShiftCmdE() {
        showFileBrowser.toggle()
    }

    // MARK: - Bundle file browser handlers

    /// Load `node` into the Monaco editor via the existing `switchEditingFile`
    /// helper. Binary files are opened in Finder instead — the editor can't
    /// render them.
    private func openBundleFileNode(_ node: BundleFileNode, bundle: PresetBundle) {
        if case .binaryFile = node.kind {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
            return
        }
        // Map the tree node to the picker's entry type so the existing
        // switchEditingFile path handles the buffer swap + Monaco language
        // mode selection.
        let entry: BundleFileEntry
        switch node.kind {
        case .entryScript:
            entry = BundleFileEntry(
                url: node.url,
                relativePath: node.relativePath,
                kind: .entryScript
            )
        case .manifest:
            entry = BundleFileEntry(
                url: node.url,
                relativePath: node.relativePath,
                kind: .manifest
            )
        default:
            entry = BundleFileEntry(
                url: node.url,
                relativePath: node.relativePath,
                kind: .uiAsset
            )
        }
        switchEditingFile(to: entry, in: bundle)
    }

    private func createBundleFile(
        parent: String, name: String,
        template: PresetManager.NewFileTemplate,
        bundle: PresetBundle
    ) {
        let relPath = parent.isEmpty ? name : "\(parent)/\(name)"
        do {
            let url = try presetManager.createBundleFile(
                in: bundle, relativePath: relPath, template: template
            )
            recordBundleEdit(path: url, message: "Add \(relPath)")
            // Open the new file immediately — users who just typed a name
            // expect to land in the editor, not to have to click again.
            let entry = BundleFileEntry(
                url: url, relativePath: relPath, kind: .uiAsset
            )
            switchEditingFile(to: entry, in: bundle)
        } catch {
            errorMessage = "Could not create \(relPath): \(error.localizedDescription)"
        }
    }

    private func createBundleFolder(parent: String, name: String, bundle: PresetBundle) {
        let relPath = parent.isEmpty ? name : "\(parent)/\(name)"
        do {
            // Folders with no files don't show up in git, so we drop a
            // `.gitkeep` sentinel alongside so the commit captures the
            // intent. Empty folders are a foot-gun otherwise.
            _ = try presetManager.createBundleFolder(in: bundle, relativePath: relPath)
            let keep = try presetManager.createBundleFile(
                in: bundle, relativePath: "\(relPath)/.gitkeep", template: .empty
            )
            recordBundleEdit(path: keep, message: "Add \(relPath)/")
        } catch {
            errorMessage = "Could not create \(relPath): \(error.localizedDescription)"
        }
    }

    private func renameBundleEntry(
        node: BundleFileNode, newName: String, bundle: PresetBundle
    ) {
        // Compute the new relative path by swapping the last component.
        let parent = (node.relativePath as NSString).deletingLastPathComponent
        let newRel = parent.isEmpty ? newName : "\(parent)/\(newName)"
        do {
            let result = try presetManager.renameBundleFile(
                in: bundle, from: node.relativePath, to: newRel
            )
            // If the Monaco editor had this file open, swap the buffer to
            // the new URL so the editor doesn't keep pointing at a
            // file-system path that no longer exists.
            if editingBundleFile?.url == result.oldURL, let newBundle = presetManager.currentBundle {
                let entry = BundleFileEntry(
                    url: result.newURL,
                    relativePath: newRel,
                    kind: node.kind == .entryScript ? .entryScript
                        : node.kind == .manifest ? .manifest
                        : .uiAsset
                )
                switchEditingFile(to: entry, in: newBundle)
            }
            let message = "Rename \(node.relativePath) \u{2192} \(newRel)"
            Task { @MainActor in
                var paths: [URL] = [result.oldURL, result.newURL]
                if let m = result.manifestURL { paths.append(m) }
                _ = await gitCoordinator.recordRename(
                    oldPath: result.oldURL, newPath: result.newURL, message: message
                )
                if result.manifestURL != nil {
                    // Rename-only commit might miss manifest edits depending
                    // on how the worker stages paths; explicit save covers it.
                    _ = await gitCoordinator.recordSave(
                        paths: paths, message: message
                    )
                }
            }
        } catch {
            errorMessage = "Could not rename: \(error.localizedDescription)"
        }
    }

    private func deleteBundleEntry(node: BundleFileNode, bundle: PresetBundle) {
        let removedURL = node.url
        do {
            try presetManager.deleteBundleFile(in: bundle, relativePath: node.relativePath)
            // If Monaco had the removed file open, fall back to the entry
            // script so the editor doesn't render stale content.
            if editingBundleFile?.url == removedURL {
                editingBundleFile = nil
                if let source = try? String(contentsOf: bundle.entryScriptURL, encoding: .utf8) {
                    scriptSource = source
                }
            }
            Task { @MainActor in
                _ = await gitCoordinator.recordDelete(
                    path: removedURL, message: "Delete \(node.relativePath)"
                )
            }
        } catch {
            errorMessage = "Could not delete: \(error.localizedDescription)"
        }
    }

    private func duplicateBundleEntry(node: BundleFileNode, bundle: PresetBundle) {
        do {
            let copyURL = try presetManager.duplicateBundleFile(
                in: bundle, relativePath: node.relativePath
            )
            let rootPath = bundle.rootURL.standardizedFileURL.path
            let copyPath = copyURL.standardizedFileURL.path
            let copyRel = copyPath.hasPrefix(rootPath + "/")
                ? String(copyPath.dropFirst(rootPath.count + 1))
                : copyURL.lastPathComponent
            recordBundleEdit(
                path: copyURL,
                message: "Duplicate \(node.relativePath) \u{2192} \(copyRel)"
            )
        } catch {
            errorMessage = "Could not duplicate: \(error.localizedDescription)"
        }
    }

    private func duplicateFactoryBundleAndEdit(
        sourceNode: BundleFileNode, factoryBundle: PresetBundle
    ) {
        do {
            let forked = try presetManager.duplicateFactoryBundle(source: factoryBundle)
            // Commit the forked bundle as one unit so `git log` shows a
            // single "Duplicate <name> from factory" entry for the whole
            // copy, not a per-file sequence.
            Task { @MainActor in
                _ = await gitCoordinator.recordSave(
                    paths: [forked.rootURL],
                    message: "Duplicate \(factoryBundle.name) from factory"
                )
            }
            // Switch the active preset to the fork, then open the
            // equivalent file. The tree's `relativePath` is preserved
            // verbatim by the copy, so opening by relative path works.
            if let preset = presetManager.presets.first(where: { $0.id == "user:\(forked.name)" }) {
                let source = (try? forked.readSource()) ?? scriptSource
                presetManager.setCurrentPreset(preset, source: source)
                scriptSource = source
                lastRunSource = source
                selectedLanguage = forked.language

                // Open the equivalent file if it's editable. Binary / entry
                // / manifest all still land at a sensible starting point.
                let targetURL = forked.rootURL.appendingPathComponent(sourceNode.relativePath)
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    let entry = BundleFileEntry(
                        url: targetURL,
                        relativePath: sourceNode.relativePath,
                        kind: sourceNode.kind == .entryScript ? .entryScript
                            : sourceNode.kind == .manifest ? .manifest
                            : .uiAsset
                    )
                    switchEditingFile(to: entry, in: forked)
                }
            }
        } catch {
            errorMessage = "Could not duplicate bundle: \(error.localizedDescription)"
        }
    }

    /// Fire-and-forget commit for a single-file bundle mutation. The
    /// coordinator swallows errors into its own surfaced push-failure state;
    /// we just need the commit to fire on the main actor.
    private func recordBundleEdit(path: URL, message: String) {
        Task { @MainActor in
            _ = await gitCoordinator.recordSave(paths: [path], message: message)
        }
    }

    private func handleResult(_ result: ScriptSaveResult) {
        if result.success {
            errorMessage = nil
            warningMessage = result.warning
            editorMarkers = []
            if let processTimeMs = result.processTimeMs, let budgetMs = result.budgetMs {
                lastBenchmark = (processTimeMs, budgetMs)
            } else {
                lastBenchmark = nil
            }
        } else {
            lastBenchmark = nil
            warningMessage = nil
            let errorStr = result.error ?? "Unknown error"
            errorMessage = errorStr
            let parsed = ErrorLineParser.parse(errorStr, language: selectedLanguage)
            editorMarkers = parsed.map { m in
                MonacoEditorView.Marker(
                    startLine: m.line,
                    startColumn: m.column,
                    message: m.message,
                    severity: m.severity
                )
            }
        }
    }

    private func chatTabButton(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let identifier = label == "Terminal" ? "claudeCodeTabButton" : "aiPromptTabButton"
        return Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    isSelected
                        ? (colorScheme == .dark
                            ? Color(white: 0.20)
                            : Color(nsColor: .controlBackgroundColor))
                        : Color.clear
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Status Bar

private struct MeterBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
                    .animation(.linear(duration: 0.1), value: fraction)
            }
        }
        .frame(width: 28, height: 4)
    }
}

private struct StatusBarView: View {
    var isCompiling: Bool
    var errorMessage: String?
    var warningMessage: String?
    @ObservedObject var processProfiler: ProcessProfiler
    @ObservedObject var memoryMonitor: MemoryMonitor
    var lastBenchmark: (processTimeMs: Double, budgetMs: Double)?
    var buildIDFormatted: String?
    var onCopyError: () -> Void

    /// Convert milliseconds to a sample frame count using the profiler's current sample rate.
    private func frames(_ ms: Double) -> Int {
        guard processProfiler.sampleRate > 0 else { return 0 }
        return Int((ms / 1000.0 * processProfiler.sampleRate).rounded())
    }

    private var timingColor: Color {
        let ratio: Double
        if processProfiler.isActive && processProfiler.budgetMs > 0 {
            ratio = processProfiler.peakMs / processProfiler.budgetMs
        } else if let b = lastBenchmark, b.budgetMs > 0 {
            ratio = b.processTimeMs / b.budgetMs
        } else {
            return .green
        }
        if ratio > 1.0 { return .red }
        if ratio > 0.5 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 6) {
            if isCompiling {
                ProgressView()
                    .controlSize(.small)
                Text("Compiling\u{2026}")
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("compilingStatus")
            } else if let err = errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .lineLimit(3)
                    .accessibilityIdentifier("errorStatus")
                Button(action: onCopyError) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            } else if let warn = warningMessage {
                Image(systemName: "info.circle")
                    .foregroundColor(.orange)
                Text(warn)
                    .foregroundColor(.orange)
                    .lineLimit(3)
                    .accessibilityIdentifier("warningStatus")
            } else if processProfiler.isActive {
                let budget = processProfiler.budgetMs
                let avgFrac = budget > 0 ? processProfiler.avgMs / budget : 0
                let peakFrac = budget > 0 ? processProfiler.peakMs / budget : 0
                let budgetFr = Int(processProfiler.maxFrames)

                HStack(spacing: 4) {
                    MeterBar(fraction: avgFrac, color: timingColor)
                    Text(String(format: "%.1fms (%dfr)", processProfiler.avgMs, frames(processProfiler.avgMs)))
                        .accessibilityIdentifier("profilerStatus")
                }
                .help(String(format: "avg %.2fms (%d frames)", processProfiler.avgMs, frames(processProfiler.avgMs)))

                HStack(spacing: 4) {
                    MeterBar(fraction: peakFrac, color: timingColor)
                    Text(String(format: "%.1fms pk (%dfr)", processProfiler.peakMs, frames(processProfiler.peakMs)))
                }
                .help(String(format: "peak %.2fms (%d frames)", processProfiler.peakMs, frames(processProfiler.peakMs)))

                Text(String(format: "budget %.1fms (%dfr)", budget, budgetFr))
                    .foregroundColor(.secondary)
                    .help(String(format: "buffer budget: %.2fms = %d frames @ %.0f Hz", budget, budgetFr, processProfiler.sampleRate))

                if memoryMonitor.leakStatus != .ok {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(memoryMonitor.leakStatus == .critical ? Color.red : Color.orange)
                            .frame(width: 5, height: 5)
                        Text("+\(String(format: "%.0f", memoryMonitor.growthMB))MB")
                            .foregroundColor(memoryMonitor.leakStatus == .critical ? .red : .orange)
                            .accessibilityIdentifier("memoryWarning")
                    }
                }
            } else if let b = lastBenchmark {
                let frac = b.budgetMs > 0 ? b.processTimeMs / b.budgetMs : 0
                let budgetFr = Int(processProfiler.maxFrames)
                HStack(spacing: 4) {
                    MeterBar(fraction: frac, color: timingColor)
                    Text(String(format: "%.1fms (%dfr)", b.processTimeMs, frames(b.processTimeMs)))
                        .foregroundColor(timingColor)
                        .accessibilityIdentifier("successStatus")
                    Text(String(format: "/ budget %.1fms (%dfr)", b.budgetMs, budgetFr))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Ready")
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let formatted = buildIDFormatted {
                Text(verbatim: "Build \(formatted)")
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("buildIDLabel")
            }
        }
        .font(.caption.monospaced())
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

// MARK: - NAM tone smart insertion

/// Splice a NAM tone into an existing script following language conventions:
/// imports go to the top of the file, and the `model = load_model(...)` /
/// `conjuredsp::nam!(...)` instantiation is placed directly above the
/// `process` function with a preceding comment carrying the tone title and URL.
///
/// The original `source` is returned unchanged in the `language` branch that
/// doesn't match, and instantiation falls back to end-of-file when no
/// `process` function is found (keeps the operation non-destructive).
func insertNAMTone(into source: String, insertion: NAMToneInsertion, language: ScriptLanguage) -> String {
    switch language {
    case .python:
        return insertPythonNAMTone(into: source, insertion: insertion)
    case .rust:
        return insertRustNAMTone(into: source, insertion: insertion)
    }
}

private func insertPythonNAMTone(into source: String, insertion: NAMToneInsertion) -> String {
    let importLine = "from conjuredsp.nam import load_model"
    let path = "tone3000://\(insertion.toneId)/\(insertion.modelId)"
    var lines = source.components(separatedBy: "\n")

    // 1. Add the import at the top if not already present. Place it after the
    //    last contiguous import/from line at the head of the file (skipping
    //    leading comments and blank lines).
    let hasImport = lines.contains { $0.trimmingCharacters(in: .whitespaces) == importLine }
    if !hasImport {
        var lastImportIdx = -1
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("import ") || t.hasPrefix("from ") {
                lastImportIdx = i
            } else if !t.isEmpty && !t.hasPrefix("#") && lastImportIdx >= 0 {
                break
            }
        }
        if lastImportIdx >= 0 {
            lines.insert(importLine, at: lastImportIdx + 1)
        } else {
            lines.insert(importLine, at: 0)
        }
    }

    // 2. Build the instantiation block: title + optional URL comment + call.
    var block: [String] = ["# \(insertion.title)"]
    if let url = insertion.url, !url.isEmpty {
        block.append("# \(url)")
    }
    block.append("model = load_model(\"\(path)\")")

    // 3. Insert the block directly above `def process(`, preserving one blank
    //    line of separation on each side.
    let processIdx = lines.firstIndex { $0.hasPrefix("def process(") }
    spliceBlock(block, intoLines: &lines, above: processIdx)
    return lines.joined(separator: "\n")
}

private func insertRustNAMTone(into source: String, insertion: NAMToneInsertion) -> String {
    let path = "tone3000://\(insertion.toneId)/\(insertion.modelId)"
    var lines = source.components(separatedBy: "\n")

    var block: [String] = ["// \(insertion.title)"]
    if let url = insertion.url, !url.isEmpty {
        block.append("// \(url)")
    }
    block.append("conjuredsp::nam!(\"\(path)\");")

    // Locate `fn process(` (with or without `pub extern "C"`). Walk back over
    // any attribute lines (`#[no_mangle]`, etc.) so the comment sits above the
    // attributes, not between them and the fn.
    var processIdx: Int? = nil
    for (i, line) in lines.enumerated() {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("pub extern \"C\" fn process(")
            || t.hasPrefix("pub fn process(")
            || t.hasPrefix("fn process(")
            || t.contains(" fn process(") {
            processIdx = i
            break
        }
    }
    if var idx = processIdx {
        while idx > 0 && lines[idx - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#[") {
            idx -= 1
        }
        spliceBlock(block, intoLines: &lines, above: idx)
    } else {
        spliceBlock(block, intoLines: &lines, above: nil)
    }
    return lines.joined(separator: "\n")
}

/// Splice `block` into `lines` directly above `idx`, ensuring one blank line
/// above and below. If `idx` is nil, append to the end of the file instead.
private func spliceBlock(_ block: [String], intoLines lines: inout [String], above idx: Int?) {
    guard let idx else {
        if let last = lines.last, !last.isEmpty {
            lines.append("")
        }
        lines.append(contentsOf: block)
        return
    }
    var toInsert = block
    // Blank line between block and the following line.
    toInsert.append("")
    // Blank line between preceding content and our block (if needed).
    if idx > 0 && !lines[idx - 1].trimmingCharacters(in: .whitespaces).isEmpty {
        toInsert.insert("", at: 0)
    }
    lines.insert(contentsOf: toInsert, at: idx)
}
