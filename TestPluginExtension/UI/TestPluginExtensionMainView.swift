//
//  TestPluginExtensionMainView.swift
//  TestPluginExtension
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

struct TestPluginExtensionMainView: View {
    var buildID: Int
    var defaultScriptSource: String
    var scriptSourcePublisher: AnyPublisher<String, Never>?
    @ObservedObject var presetManager: PresetManager
    var onRun: (String) -> ScriptSaveResult
    var onSelectPreset: (Preset) -> Void
    var onSavePreset: (String) -> ScriptSaveResult
    var onSaveAsPreset: (String, String) -> ScriptSaveResult
    var onDeletePreset: () -> Void
    var onNew: () -> ScriptSaveResult

    @State private var scriptSource: String = ""
    @State private var errorMessage: String?
    @State private var showingSaveAs = false
    @State private var saveAsName = ""
    @State private var showSuccess: Bool = false
    @State private var lastBenchmark: (processTimeMs: Double, budgetMs: Double)?
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
                onSelectPreset: { preset in
                    onSelectPreset(preset)
                },
                onRun: {
                    let result = onRun(scriptSource)
                    handleResult(result)
                },
                onSave: {
                    let result = onSavePreset(scriptSource)
                    handleResult(result)
                },
                onSaveAs: { name in
                    let result = onSaveAsPreset(name, scriptSource)
                    handleResult(result)
                },
                onDelete: {
                    onDeletePreset()
                },
                onNew: {
                    let result = onNew()
                    handleResult(result)
                },
                showingSaveAs: $showingSaveAs,
                saveAsName: $saveAsName
            )

            Divider()

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

                HighlightedTextEditor(text: $scriptSource, colorScheme: colorScheme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .border(Color.secondary.opacity(0.3), width: 1)
                    .padding(.horizontal)
                    .padding(.top, buildID != 0 ? 0 : 8)

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if showSuccess {
                    if let benchmark = lastBenchmark {
                        Text(String(format: "Script reloaded — %.1fms / %.1fms budget", benchmark.processTimeMs, benchmark.budgetMs))
                            .foregroundColor(benchmarkColor)
                            .font(.caption)
                            .padding(.horizontal)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Script reloaded successfully")
                            .foregroundColor(.green)
                            .font(.caption)
                            .padding(.horizontal)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .onAppear {
            scriptSource = defaultScriptSource
        }
        .onReceive(scriptSourcePublisher ?? Empty().eraseToAnyPublisher()) { newSource in
            scriptSource = newSource
        }
        .onChange(of: scriptSource) { _, newValue in
            presetManager.scriptDidChange(to: newValue)
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
            let result = onSavePreset(scriptSource)
            handleResult(result)
        } else {
            saveAsName = presetManager.currentPreset?.name ?? ""
            showingSaveAs = true
        }
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
