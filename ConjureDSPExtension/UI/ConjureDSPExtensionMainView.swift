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
    @ObservedObject var aiService: AIService
    @ObservedObject var chatService: ChatService
    @ObservedObject var captureManager: AudioCaptureManager
    @ObservedObject var parameterState: ParameterState
    @ObservedObject var licenseManager: LicenseManager
    @ObservedObject var gitHubService: GitHubService
    var onRun: (String) async -> ScriptSaveResult
    var onSelectPreset: (Preset) async -> ScriptSaveResult
    var onSavePreset: (String, ScriptLanguage) -> ScriptSaveResult
    var onSaveAsPreset: (String, String, ScriptLanguage) -> ScriptSaveResult
    var onDeletePreset: () -> Void
    var onNew: (ScriptLanguage) -> ScriptSaveResult
    var onExport: (String) async -> ExportResult
    var defaultBenchmark: (processTimeMs: Double, budgetMs: Double)?

    @State private var scriptSource: String = ""
    @State private var selectedLanguage: ScriptLanguage = .python
    @State private var errorMessage: String?
    @State private var showingSaveAs = false
    @State private var saveAsName = ""
    @State private var lastBenchmark: (processTimeMs: Double, budgetMs: Double)?
    @State private var showNewScriptDialog: Bool = false
    @State private var isCompiling: Bool = false
    @State private var lastRunSource: String = ""
    @State private var showSpectrogram: Bool = false
    @State private var showChat: Bool = false
    @State private var chatWidth: CGFloat = 280
    @State private var useTerminalMode: Bool = false
    @State private var isExporting: Bool = false
    @State private var exportAlertMessage: String?
    @State private var showExportAlert: Bool = false
    @State private var spectrogramWidth: CGFloat = 250
    @State private var spectrogramFrequencyScale: FrequencyScale = .log
    @State private var spectrogramFFTSizeIndex: Int = 2 // default: 2048
    @State private var spectrogramShowNoteNames: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    /// Color for the benchmark timing based on how close to budget.
    private var benchmarkColor: Color {
        guard let benchmark = lastBenchmark else { return .green }
        let ratio = benchmark.processTimeMs / benchmark.budgetMs
        if ratio > 1.0 { return .red }
        if ratio > 0.5 { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 0) {
            // Preset toolbar
            PresetToolbar(
                presetManager: presetManager,
                aiService: aiService,
                licenseManager: licenseManager,
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
                onNew: { language in
                    selectedLanguage = language
                    let result = onNew(language)
                    handleResult(result)
                    chatService.clearConversation()
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
                saveAsName: $saveAsName
            )

            Divider()

            ParameterSlidersView(parameterState: parameterState)

            Divider()

            ZStack {
            HStack(spacing: 0) {
            // AI sidebar (collapsible, left side) — Chat or Terminal mode
            if showChat {
                VStack(spacing: 0) {
                    // Mode toggle
                    HStack(spacing: 0) {
                        Button(action: { useTerminalMode = false }) {
                            Text("Chat")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(useTerminalMode ? Color.clear : Color.accentColor.opacity(0.15))
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)

                        Button(action: { useTerminalMode = true }) {
                            HStack(spacing: 3) {
                                Image(systemName: "terminal")
                                    .font(.caption2)
                                Text("Claude Code")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(useTerminalMode ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                    Divider()

                    if useTerminalMode {
                        TerminalView(colorScheme: colorScheme)
                    } else {
                        ChatSidebarView(chatService: chatService)
                    }
                }
                .frame(width: chatWidth)

                // Resizable divider
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 4)
                    .contentShape(Rectangle().inset(by: -4))
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                chatWidth = max(200, min(450, chatWidth + value.translation.width))
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
                MonacoEditorView(
                    text: $scriptSource,
                    colorScheme: colorScheme,
                    language: selectedLanguage,
                    isEditable: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(Color.secondary.opacity(0.3), width: 1)
                .padding(.horizontal)
                .padding(.top, 8)

                // Persistent status bar
                HStack(spacing: 4) {
                    if isCompiling {
                        ProgressView()
                            .controlSize(.small)
                        Text("Compiling\u{2026}")
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("compilingStatus")
                    } else if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .lineLimit(3)
                            .accessibilityIdentifier("errorStatus")
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(errorMessage, forType: .string)
                        }) {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    } else if let benchmark = lastBenchmark {
                        Text(String(format: "%.1fms / %.1fms budget", benchmark.processTimeMs, benchmark.budgetMs))
                            .foregroundColor(benchmarkColor)
                            .accessibilityIdentifier("successStatus")
                    } else {
                        Text("Ready")
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if buildID != 0 {
                        Text(verbatim: "Build \(buildID)")
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("buildIDLabel")
                    }
                }
                .font(.caption.monospaced())
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            .padding(.bottom, 4)

            // Spectrogram side panel (collapsible)
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
            }
            } // HStack

            // Demo expired overlay
            if !licenseManager.isLicensed && licenseManager.demoSecondsRemaining <= 0 {
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
                            licenseManager.restartDemo()
                        } label: {
                            Text("Restart Demo")
                                .frame(minWidth: 160)
                        }
                        .controlSize(.large)
                        .accessibilityIdentifier("restartDemoButton")

                        Button {
                            showingSaveAs = false // dismiss any other popover
                            // Open settings by triggering the toolbar gear button
                            NotificationCenter.default.post(name: .openLicenseSettings, object: nil)
                        } label: {
                            Text("Enter License Key")
                                .frame(minWidth: 160)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
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

    private func handleCmdS() {
        if canSave {
            let result = onSavePreset(scriptSource, selectedLanguage)
            handleResult(result)
        } else {
            saveAsName = presetManager.currentPreset?.name ?? ""
            showingSaveAs = true
        }
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
            if let processTimeMs = result.processTimeMs, let budgetMs = result.budgetMs {
                lastBenchmark = (processTimeMs, budgetMs)
            } else {
                lastBenchmark = nil
            }
        } else {
            lastBenchmark = nil
            errorMessage = result.error ?? "Unknown error"
        }
    }
}
