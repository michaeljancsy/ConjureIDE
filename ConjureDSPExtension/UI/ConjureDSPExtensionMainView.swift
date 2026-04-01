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
    let processTimeMs: Double?
    let budgetMs: Double?
}

struct ConjureDSPExtensionMainView: View {
    var buildID: Int
    var defaultScriptSource: String
    var defaultLanguage: ScriptLanguage = .python
    var extensionBundle: Bundle
    var scriptSourcePublisher: AnyPublisher<ConjureDSPExtensionAudioUnit.ScriptSourceChange, Never>?
    @ObservedObject var presetManager: PresetManager
    @ObservedObject var captureManager: AudioCaptureManager
    @ObservedObject var processProfiler: ProcessProfiler
    @ObservedObject var memoryMonitor: MemoryMonitor
    @ObservedObject var parameterState: ParameterState
    @ObservedObject var subscriptionManager: SubscriptionManager
    @ObservedObject var gitHubService: GitHubService
    var onRun: (String) async -> ScriptSaveResult
    var onSelectPreset: (Preset) async -> ScriptSaveResult
    var onSavePreset: (String, ScriptLanguage) -> ScriptSaveResult
    var onSaveAsPreset: (String, String, ScriptLanguage) -> ScriptSaveResult
    var onDeletePreset: () -> Void
    var onRenamePreset: (String) -> String?
    var onNew: (ScriptLanguage) -> ScriptSaveResult
    var onExport: (String) async -> ExportResult
    var defaultBenchmark: (processTimeMs: Double, budgetMs: Double)?
    var appGroupContainerURL: URL?

    @State private var scriptSource: String = ""
    @State private var selectedLanguage: ScriptLanguage = .python
    @State private var errorMessage: String?
    @State private var editorMarkers: [MonacoEditorView.Marker] = []
    @State private var showingSaveAs = false
    @State private var saveAsName = ""
    @State private var lastBenchmark: (processTimeMs: Double, budgetMs: Double)?
    @State private var showNewScriptDialog: Bool = false
    @State private var isCompiling: Bool = false
    @State private var lastRunSource: String = ""
    @State private var showSpectrogram: Bool = false
    @State private var showChat: Bool = false
    @State private var terminalHasBeenOpened: Bool = false
    @State private var chatWidth: CGFloat = 280
    @State private var isExporting: Bool = false
    @State private var exportAlertMessage: String?
    @State private var showExportAlert: Bool = false
    @State private var spectrogramWidth: CGFloat = 250
    @State private var spectrogramFrequencyScale: FrequencyScale = .log
    @State private var spectrogramFFTSizeIndex: Int = 2 // default: 2048
    @State private var spectrogramShowNoteNames: Bool = false
    @State private var snippetToInsert: String?
    @StateObject private var daemonChecker = DaemonStatusChecker()
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("editorTheme") private var selectedTheme: String = "auto"

    /// Resolved Monaco theme ID based on user preference and system appearance.
    private var resolvedTheme: String {
        if selectedTheme == "auto" {
            return colorScheme == .dark ? "vs-dark" : "vs"
        }
        return selectedTheme
    }

    /// Color for the timing display based on how close to budget.
    /// Uses profiler peak when live data is available, otherwise static benchmark.
    private var timingColor: Color {
        let ratio: Double
        if processProfiler.isActive && processProfiler.budgetMs > 0 {
            ratio = processProfiler.peakMs / processProfiler.budgetMs
        } else if let benchmark = lastBenchmark, benchmark.budgetMs > 0 {
            ratio = benchmark.processTimeMs / benchmark.budgetMs
        } else {
            return .green
        }
        if ratio > 1.0 { return .red }
        if ratio > 0.5 { return .orange }
        return .green
    }

    /// Format milliseconds with frame equivalent, e.g. "0.3ms (13 frames)"
    private func formatTimeWithFrames(_ ms: Double) -> String {
        let frames = ms / 1000.0 * processProfiler.sampleRate
        return String(format: "%.1fms (%d frames)", ms, Int(frames.rounded()))
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
                onSave: {
                    let result = onSavePreset(scriptSource, selectedLanguage)
                    handleResult(result)
                },
                onSaveAs: { name in
                    let result = onSaveAsPreset(name, scriptSource, selectedLanguage)
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
                showingSaveAs: $showingSaveAs,
                saveAsName: $saveAsName,
                onInsertSnippet: { snippet in
                    snippetToInsert = snippet
                }
            )

            Divider()

            ParameterSlidersView(parameterState: parameterState)

            Divider()

            ZStack {
            HStack(spacing: 0) {
            VStack(spacing: 0) {
                MonacoEditorView(
                    text: $scriptSource,
                    theme: resolvedTheme,
                    language: selectedLanguage,
                    isEditable: true,
                    markers: editorMarkers,
                    snippetToInsert: $snippetToInsert
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(Color.secondary.opacity(0.3), width: 1)
                .padding(.horizontal)
                .padding(.top, 8)

                // Persistent status bar
                StatusBarView(
                    isCompiling: isCompiling,
                    errorMessage: errorMessage,
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
            .animation(.easeOut(duration: 0.15), value: showSpectrogram)

            // Terminal drawer — animates frame width so the WKWebView is never
            // destroyed mid-animation (avoids choppiness from WebView teardown).
            // Rendered lazily on first open, then kept alive.
            if terminalHasBeenOpened {
                HStack(spacing: 0) {
                    Group {
                        if daemonChecker.isDaemonAvailable {
                            TerminalView(colorScheme: colorScheme, appGroupContainerURL: appGroupContainerURL)
                                .accessibilityIdentifier("terminalPanel")
                        } else {
                            DaemonLaunchPromptView(colorScheme: colorScheme)
                        }
                    }
                    .frame(width: showChat ? chatWidth : 0)
                    .clipped()

                    // Drag handle (only interactive when open)
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

                    Spacer(minLength: 0)
                }
                .animation(.easeOut(duration: 0.15), value: showChat)
            }

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
        .onChange(of: showChat) { _, newValue in
            if newValue {
                terminalHasBeenOpened = true
                daemonChecker.startChecking()
            } else {
                daemonChecker.stopChecking()
            }
        }
        .onChange(of: showSpectrogram) { _, newValue in
            captureManager.isActive = newValue
        }
        .onAppear {
            scriptSource = defaultScriptSource
            lastRunSource = defaultScriptSource
            selectedLanguage = defaultLanguage
            if let bench = defaultBenchmark {
                lastBenchmark = bench
            }
        }
        .onReceive(scriptSourcePublisher ?? Empty().eraseToAnyPublisher()) { change in
            scriptSource = change.source
            lastRunSource = change.source
            selectedLanguage = ScriptLanguage.detect(from: change.source)
            // Clear error — this fires after successful compile (preset select, AI fix, fullState restore)
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
                Button(action: handleSaveAs) { EmptyView() }
                    .keyboardShortcut("A", modifiers: .command)
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

    private func handleCmdS() {
        if canSave {
            let result = onSavePreset(scriptSource, selectedLanguage)
            handleResult(result)
        } else {
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
            editorMarkers = []
            if let processTimeMs = result.processTimeMs, let budgetMs = result.budgetMs {
                lastBenchmark = (processTimeMs, budgetMs)
            } else {
                lastBenchmark = nil
            }
        } else {
            lastBenchmark = nil
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
    @ObservedObject var processProfiler: ProcessProfiler
    @ObservedObject var memoryMonitor: MemoryMonitor
    var lastBenchmark: (processTimeMs: Double, budgetMs: Double)?
    var buildIDFormatted: String?
    var onCopyError: () -> Void

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
            } else if processProfiler.isActive {
                let budget = processProfiler.budgetMs
                let avgFrac = budget > 0 ? processProfiler.avgMs / budget : 0
                let peakFrac = budget > 0 ? processProfiler.peakMs / budget : 0

                HStack(spacing: 4) {
                    MeterBar(fraction: avgFrac, color: timingColor)
                    Text(String(format: "%.1fms", processProfiler.avgMs))
                        .accessibilityIdentifier("profilerStatus")
                }
                .help(String(format: "avg %.1fms / %.1fms budget", processProfiler.avgMs, budget))

                HStack(spacing: 4) {
                    MeterBar(fraction: peakFrac, color: timingColor)
                    Text(String(format: "%.1fms pk", processProfiler.peakMs))
                }
                .help(String(format: "peak %.1fms / %.1fms budget", processProfiler.peakMs, budget))

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
                HStack(spacing: 4) {
                    MeterBar(fraction: frac, color: timingColor)
                    Text(String(format: "%.1fms / %.1fms", b.processTimeMs, b.budgetMs))
                        .foregroundColor(timingColor)
                        .accessibilityIdentifier("successStatus")
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
