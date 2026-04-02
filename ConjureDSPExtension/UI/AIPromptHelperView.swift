//
//  AIPromptHelperView.swift
//  ConjureDSPExtension
//
//  Copy-paste prompt helper for users without a Claude Code subscription.
//  Assembles a self-contained prompt (API docs + current script + user description)
//  for pasting into any AI chatbot (ChatGPT, Claude.ai, Gemini, etc.).
//

import SwiftUI

struct AIPromptHelperView: View {
    var currentScript: String
    var currentLanguage: ScriptLanguage
    var colorScheme: ColorScheme

    @State private var userDescription: String = ""
    @State private var includeScript: Bool = true
    @State private var selectedLanguage: ScriptLanguage = .python
    @State private var copyConfirmed: Bool = false

    private var effectiveLanguage: ScriptLanguage {
        (includeScript && !currentScript.isEmpty) ? currentLanguage : selectedLanguage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Description field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What would you like to build?")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextEditor(text: $userDescription)
                            .font(.system(size: 12))
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(colorScheme == .dark
                                        ? Color(white: 0.18)
                                        : Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                            .overlay(alignment: .topLeading) {
                                if userDescription.isEmpty {
                                    Text("e.g. \"A tremolo effect with rate and depth controls\"")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary.opacity(0.6))
                                        .padding(EdgeInsets(top: 8, leading: 5, bottom: 0, trailing: 5))
                                        .allowsHitTesting(false)
                                }
                            }
                    }

                    // Options
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $includeScript) {
                            Text("Include current script")
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(currentScript.isEmpty)

                        // Language picker — locked to current script's language when including it
                        HStack(spacing: 6) {
                            Text("Language:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Picker("Language", selection: $selectedLanguage) {
                                Text("Python").tag(ScriptLanguage.python)
                                Text("Rust").tag(ScriptLanguage.rust)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .disabled(includeScript && !currentScript.isEmpty)
                            .opacity((includeScript && !currentScript.isEmpty) ? 0.5 : 1.0)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Copy button + instructions
            VStack(spacing: 8) {
                Button(action: copyToClipboard) {
                    HStack(spacing: 6) {
                        if copyConfirmed {
                            Image(systemName: "checkmark")
                            Text("Copied!")
                        } else {
                            Image(systemName: "doc.on.clipboard")
                            Text("Copy Prompt")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(userDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .animation(.easeInOut(duration: 0.15), value: copyConfirmed)

                Text("Paste the response into the editor and press ⌘R to run.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
        }
        .background(colorScheme == .dark
            ? Color(white: 0.12)
            : Color(nsColor: .controlBackgroundColor))
        .onAppear {
            selectedLanguage = currentLanguage
        }
    }

    private func copyToClipboard() {
        let prompt = buildPrompt()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)

        withAnimation { copyConfirmed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copyConfirmed = false }
        }
    }

    private func buildPrompt() -> String {
        let lang = effectiveLanguage
        let langName: String
        let langNote: String
        let outputInstruction: String

        switch lang {
        case .python:
            langName = "Python"
            langNote = ""
            outputInstruction = "Reply with ONLY the raw Python code. No markdown code fences, no explanation. I will paste it directly into the code editor and press ⌘R to run."
        case .rust:
            langName = "Rust"
            langNote = " (compiled to WebAssembly via wasm32-wasip1)"
            outputInstruction = "Reply with ONLY the raw Rust code. No markdown code fences, no explanation. I will paste it directly into the code editor and press ⌘R to run."
        }

        var parts: [String] = []

        parts.append("""
        You are helping me write a DSP audio effect script for ConjureDSP, a macOS AUv3 plugin. \
        Scripts run in real-time audio processing. Write in \(langName)\(langNote).
        """)

        parts.append("## Task\n\n\(userDescription.trimmingCharacters(in: .whitespacesAndNewlines))")

        if includeScript && !currentScript.isEmpty {
            parts.append("## Current Script\n\n```\n\(currentScript)\n```")
        }

        parts.append("## ConjureDSP API Reference\n\n\(DSPDocumentation.allDocs)")

        parts.append("## Output Format\n\n\(outputInstruction)")

        return parts.joined(separator: "\n\n")
    }
}
