//
//  BearBoneExtensionMainView.swift
//  BearBoneExtension
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

struct BearBoneExtensionMainView: View {
    var buildID: Int
    var defaultScriptSource: String
    var defaultLanguage: ScriptLanguage = .python
    var extensionBundle: Bundle
    var scriptSourcePublisher: AnyPublisher<String, Never>?
    @ObservedObject var presetManager: PresetManager
    @ObservedObject var aiService: AIService
    @ObservedObject var captureManager: AudioCaptureManager
    @ObservedObject var parameterState: ParameterState
    @ObservedObject var licenseManager: LicenseManager
    var onRun: (String) async -> ScriptSaveResult
    var onSelectPreset: (Preset) async -> ScriptSaveResult
    var onSavePreset: (String, ScriptLanguage) -> ScriptSaveResult
    var onSaveAsPreset: (String, String, ScriptLanguage) -> ScriptSaveResult
    var onDeletePreset: () -> Void
    var onNew: (ScriptLanguage) -> ScriptSaveResult

    @State private var scriptSource: String = ""
    @State private var selectedLanguage: ScriptLanguage = .python
    @State private var errorMessage: String?
    @State private var showingSaveAs = false
    @State private var saveAsName = ""
    @State private var showSuccess: Bool = false
    @State private var lastBenchmark: (processTimeMs: Double, budgetMs: Double)?
    @State private var isCompiling: Bool = false
    @State private var showSpectrogram: Bool = false
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
                isCompiling: isCompiling,
                selectedLanguage: $selectedLanguage,
                showSpectrogram: $showSpectrogram,
                onSelectPreset: { preset in
                    Task {
                        isCompiling = true
                        selectedLanguage = preset.language
                        let result = await onSelectPreset(preset)
                        isCompiling = false
                        handleResult(result)
                    }
                },
                onRun: {
                    Task {
                        isCompiling = true
                        let result = await onRun(scriptSource)
                        isCompiling = false
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
                onNew: {
                    let result = onNew(selectedLanguage)
                    handleResult(result)
                },
                onGenerate: { prompt in
                    aiService.generate(prompt: prompt, existingScript: scriptSource, language: selectedLanguage) { accumulated in
                        scriptSource = accumulated
                    }
                },
                showingSaveAs: $showingSaveAs,
                saveAsName: $saveAsName
            )

            Divider()

            ParameterSlidersView(parameterState: parameterState)

            Divider()

            HStack(spacing: 0) {
            VStack(spacing: 8) {
                if buildID != 0 {
                    Text(verbatim: "Build \(buildID)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .accessibilityIdentifier("buildIDLabel")
                }

                HighlightedTextEditor(
                    text: $scriptSource,
                    colorScheme: colorScheme,
                    language: selectedLanguage,
                    isEditable: !aiService.isGenerating
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(
                    aiService.isGenerating ? Color.accentColor : Color.secondary.opacity(0.3),
                    width: aiService.isGenerating ? 2 : 1
                )
                .padding(.horizontal)
                .padding(.top, buildID != 0 ? 0 : 8)

                if isCompiling {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Compiling\u{2026}")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("compilingStatus")
                } else if let errorMessage = errorMessage {
                    HStack(spacing: 8) {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                            .lineLimit(3)
                            .accessibilityIdentifier("errorStatus")

                        Spacer()

                        Button("Fix with AI") {
                            aiService.fix(script: scriptSource, error: errorMessage, language: selectedLanguage) { accumulated in
                                scriptSource = accumulated
                            }
                        }
                        .font(.caption)
                        .disabled(!aiService.hasAPIKey || aiService.isGenerating)
                        .accessibilityIdentifier("fixWithAIButton")
                    }
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if showSuccess {
                    if let benchmark = lastBenchmark {
                        Text(String(format: "Script reloaded — %.1fms / %.1fms budget", benchmark.processTimeMs, benchmark.budgetMs))
                            .foregroundColor(benchmarkColor)
                            .font(.caption)
                            .padding(.horizontal)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("successStatus")
                    } else {
                        Text("Script reloaded successfully")
                            .foregroundColor(.green)
                            .font(.caption)
                            .padding(.horizontal)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("successStatus")
                    }
                }

                if case .error(let aiError) = aiService.state {
                    Text(aiError)
                        .foregroundColor(.orange)
                        .font(.caption)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, 8)

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
        }
        .onChange(of: showSpectrogram) { _, newValue in
            captureManager.isActive = newValue
        }
        .onAppear {
            scriptSource = defaultScriptSource
            selectedLanguage = defaultLanguage
        }
        .onReceive(scriptSourcePublisher ?? Empty().eraseToAnyPublisher()) { newSource in
            scriptSource = newSource
            selectedLanguage = ScriptLanguage.detect(from: newSource)
        }
        .onChange(of: scriptSource) { _, newValue in
            presetManager.scriptDidChange(to: newValue)
        }
        .onChange(of: selectedLanguage) { oldLang, newLang in
            // Swap template when switching language on a default/empty script
            if isDefaultTemplate(scriptSource, for: oldLang) {
                if let template = loadTemplate(for: newLang) {
                    scriptSource = template
                }
            }
        }
        .background(
            Button(action: handleCmdS) { EmptyView() }
                .keyboardShortcut("s", modifiers: .command)
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

    private func isDefaultTemplate(_ source: String, for language: ScriptLanguage) -> Bool {
        guard let template = loadTemplate(for: language) else { return false }
        return source.trimmingCharacters(in: .whitespacesAndNewlines) == template.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadTemplate(for language: ScriptLanguage) -> String? {
        let ext = language == .rust ? "rs" : "py"
        guard let url = extensionBundle.url(forResource: "process", withExtension: ext),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return source
    }

    private func handleResult(_ result: ScriptSaveResult) {
        if result.success {
            errorMessage = nil
            showSuccess = true
            if let processTimeMs = result.processTimeMs, let budgetMs = result.budgetMs {
                lastBenchmark = (processTimeMs, budgetMs)
            } else {
                lastBenchmark = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                showSuccess = false
            }
        } else {
            showSuccess = false
            lastBenchmark = nil
            errorMessage = result.error ?? "Unknown error"
        }
    }
}
