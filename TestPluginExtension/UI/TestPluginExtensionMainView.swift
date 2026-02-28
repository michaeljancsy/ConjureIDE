//
//  TestPluginExtensionMainView.swift
//  TestPluginExtension
//
//  Created by Michael Jancsy on 2/25/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ScriptSaveResult {
    let success: Bool
    let error: String?
    let processTimeMs: Double?
    let budgetMs: Double?
}

struct PythonScriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pythonScript, .plainText] }

    var source: String

    init(source: String) {
        self.source = source
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let source = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.source = source
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = source.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

struct TestPluginExtensionMainView: View {
    var defaultScriptSource: String
    var onReloadScript: (String) -> ScriptSaveResult

    @State private var scriptSource: String = ""
    @State private var currentFilename: String?
    @State private var currentFileURL: URL?
    @State private var errorMessage: String?
    @State private var showSuccess: Bool = false
    @State private var lastBenchmark: (processTimeMs: Double, budgetMs: Double)?
    @State private var showingSaveDialog = false
    @State private var showingOpenDialog = false
    @State private var documentToExport: PythonScriptDocument?
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
                Button("Open...") {
                    showingOpenDialog = true
                }
                .accessibilityIdentifier("openScriptButton")
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
                // Always reload kernel + benchmark
                let result = onReloadScript(scriptSource)
                handleSaveResult(result)

                if result.success {
                    if let fileURL = currentFileURL {
                        // Write to existing file
                        do {
                            try scriptSource.write(to: fileURL, atomically: true, encoding: .utf8)
                        } catch {
                            // File write failed — fall back to save dialog
                            documentToExport = PythonScriptDocument(source: scriptSource)
                            showingSaveDialog = true
                        }
                    } else {
                        // No file yet — show save dialog
                        documentToExport = PythonScriptDocument(source: scriptSource)
                        showingSaveDialog = true
                    }
                }
            }
            .accessibilityIdentifier("saveButton")
            .padding(.bottom)
        }
        .fileExporter(
            isPresented: $showingSaveDialog,
            document: documentToExport,
            contentType: .pythonScript,
            defaultFilename: currentFilename ?? "process.py"
        ) { result in
            switch result {
            case .success(let url):
                currentFileURL = url
                currentFilename = url.lastPathComponent
            case .failure(let error):
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $showingOpenDialog,
            allowedContentTypes: [.pythonScript, .plainText]
        ) { result in
            switch result {
            case .success(let url):
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { return }
                scriptSource = source
                currentFileURL = url
                currentFilename = url.lastPathComponent
                errorMessage = nil
                showSuccess = false
                lastBenchmark = nil
                let reloadResult = onReloadScript(source)
                handleSaveResult(reloadResult)
            case .failure:
                break
            }
        }
        .onAppear {
            scriptSource = defaultScriptSource
        }
    }

    private func handleSaveResult(_ result: ScriptSaveResult) {
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
