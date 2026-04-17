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
    var onSaveAsPreset: (_ name: String, _ source: String, _ language: ScriptLanguage, _ commitMessage: String?) -> ScriptSaveResult
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
    @State private var showLanguageMigrationSheet: Bool = false
    @State private var languageModuleManager = LanguageModuleManager()

    /// Current bundle build number (e.g. "15"). Used as the shown-marker key
    /// for the language migration sheet so it re-appears exactly once per
    /// upgrade and never between launches on the same build.
    private var currentBuildNumber: String {
        Bundle(for: AudioUnitViewController.self)
            .infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
    @State private var spectrogramWidth: CGFloat = 250
    @State private var spectrogramFrequencyScale: FrequencyScale = .log
    @State private var spectrogramFFTSizeIndex: Int = 2 // default: 2048
    @State private var spectrogramShowNoteNames: Bool = false
    @StateObject private var daemonChecker = DaemonStatusChecker()
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
                onSaveAs: { name, commitMessage in
                    let result = onSaveAsPreset(name, scriptSource, selectedLanguage, commitMessage)
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

            ParameterSlidersView(parameterState: parameterState)

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

            VStack(spacing: 0) {
                MonacoEditorView(
                    text: $scriptSource,
                    theme: resolvedTheme,
                    language: selectedLanguage,
                    isEditable: true,
                    markers: editorMarkers,
                    snippetToInsert: .constant(nil),
                    flashToken: mcpFlashToken
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .sheet(isPresented: $showLanguageMigrationSheet) {
            LanguageMigrationSheet(manager: languageModuleManager) {
                LanguageMigrationCoordinator.markShown(currentBuild: currentBuildNumber)
                showLanguageMigrationSheet = false
            }
        }
        .onChange(of: showChat) { _, newValue in
            if newValue {
                terminalHasBeenOpened = true
            }
            Analytics.track(.terminalToggle, properties: ["opened": newValue])
        }
        .onChange(of: showSpectrogram) { _, newValue in
            captureManager.isActive = newValue
            Analytics.track(.spectrogramToggle, properties: ["opened": newValue])
        }
        .onAppear {
            scriptSource = defaultScriptSource
            lastRunSource = defaultScriptSource
            selectedLanguage = defaultLanguage
            if let bench = defaultBenchmark {
                lastBenchmark = bench
            }
            bypassed = isBypassed()
            daemonChecker.startChecking(instanceID: instanceID, appGroupContainerURL: appGroupContainerURL)

            // First launch in a fresh App Group container (no modules installed
            // yet, no prior "shown" marker): present the welcome sheet so the
            // user picks which DSP-language runtimes to install up front.
            if LanguageMigrationCoordinator.shouldShow(
                currentBuild: currentBuildNumber,
                defaults: LanguageMigrationCoordinator.defaults,
                isInstalled: { LanguageModuleManager.isInstalled($0) }
            ) {
                showLanguageMigrationSheet = true
            }

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
