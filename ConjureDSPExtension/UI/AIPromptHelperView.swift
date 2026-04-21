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
                            .accessibilityIdentifier("aiPromptDescriptionField")
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
                            Text("Include current script as context in prompt")
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(currentScript.isEmpty)

                        // Language picker — locked to current script's language when including it
                        HStack(spacing: 6) {
                            Text("Target language:")
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
                .accessibilityIdentifier("aiPromptCopyButton")
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
            outputInstruction = "Reply with only the raw code inside markdown code fences (backticks). I will paste your output directly into the code editor and press cmd+R to run."
        case .rust:
            langName = "Rust"
            langNote = " (compiled to WebAssembly via wasm32-wasip1)"
            outputInstruction = "Reply with only the raw code inside markdown code fences (backticks). I will paste your output directly into the code editor and press cmd+R to run."
        }

        let conventions: String
        switch lang {
        case .python:
            conventions = """
            ## Python Conventions

            - All imports must be at module scope (top of file), never inside `process()`.
            - Pre-allocate fixed-size state (numpy arrays, lists) at module scope. For objects that depend on `sample_rate` (e.g., LFO, DelayLine with time-based sizing), lazy-initialize on the first `process()` call and re-create only when `sample_rate` changes.
            - Initialize gain/envelope state variables to `1.0` (unity gain), not `0.0`.
            - For LFO modulation, prefer `lfo.tick_n(frame_count)` to generate a full buffer of modulation values at once, then apply with numpy. Avoid calling `lfo.tick()` in a per-sample loop.
            - Use numpy vectorized operations over per-sample Python loops wherever the algorithm allows it.
            - `inputs` and `outputs` are **lists of 1D numpy float32 arrays**, one per channel — NOT a 2D array. Use `len(inputs)` for channel count, `inputs[ch][i]` for per-sample access, and `inputs[ch][:frame_count]` for channel slices.
            """
        case .rust:
            conventions = """
            ## Rust Conventions

            - Declare all static state with `static mut` at module scope (e.g., filters, delay lines, LFO).
            - Call `lfo.init(ctx.sample_rate() as f64, ctx.param(RATE) as f64)` at the start of each `process()` callback. Both args are f64; cast f32 values with `as f64`.
            - Use `unsafe` blocks for `static mut` access.
            - Initialize gain/envelope state to `1.0f32` (unity gain), not `0.0`.
            """
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

        parts.append(conventions)

        parts.append("## Output Format\n\n\(outputInstruction)")

        return parts.joined(separator: "\n\n")
    }
}
