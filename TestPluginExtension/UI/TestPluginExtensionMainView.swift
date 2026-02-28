//
//  TestPluginExtensionMainView.swift
//  TestPluginExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import SwiftUI

struct ScriptSaveResult {
    let success: Bool
    let error: String?
    let processTimeMs: Double?
    let budgetMs: Double?
}

struct TestPluginExtensionMainView: View {
    var defaultScriptSource: String
    var onSave: (String) -> ScriptSaveResult
    var onOpen: (() -> (source: String, filename: String)?)?

    @State private var scriptSource: String = ""
    @State private var currentFilename: String?
    @State private var errorMessage: String?
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

    private var titleText: String {
        if let filename = currentFilename {
            return "Python DSP Script — \(filename)"
        }
        return "Python DSP Script — Untitled"
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(titleText)
                    .font(.headline)
                    .accessibilityIdentifier("scriptTitle")
                Spacer()
                if onOpen != nil {
                    Button("Open...") {
                        guard let result = onOpen?() else { return }
                        scriptSource = result.source
                        currentFilename = result.filename
                        errorMessage = nil
                        showSuccess = false
                        lastBenchmark = nil
                    }
                    .accessibilityIdentifier("openScriptButton")
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            HighlightedTextEditor(text: $scriptSource, colorScheme: colorScheme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(Color.secondary.opacity(0.3), width: 1)
                .padding(.horizontal)

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

            Button("Save") {
                let result = onSave(scriptSource)
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
            .accessibilityIdentifier("saveButton")
            .padding(.bottom)
        }
        .onAppear {
            scriptSource = defaultScriptSource
        }
    }
}
