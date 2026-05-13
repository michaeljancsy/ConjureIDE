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
            - `ctx.inputs` and `ctx.outputs` are **2D numpy float32 arrays** of shape `(channels, frame_count)`, pre-sliced to the current block. Prefer whole-array ops (`np.multiply(ctx.inputs, gain, out=ctx.outputs)`, `ctx.outputs[:] = ctx.inputs * gain`) — they broadcast across both axes via SIMD. Use `ctx.inputs.shape[0]` for channel count and `ctx.inputs[ch]` for a contiguous 1D row view when per-channel state (stateful filters, IIR feedback) forces a loop. Explicit `[:ctx.frame_count]` slicing is unnecessary on these arrays.
            """
        case .rust:
            conventions = """
            ## Rust Conventions

            - Entry point is **`process! { ctx => /* body */ }`** — emits the zero-arg `extern "C" fn process()` WASM export the host calls and sets up the buffer statics in one shot. Do **not** write `setup!();` separately (it triggers a duplicate-static error because `process!` invokes `setup!()` internally) and do **not** hand-roll an `extern "C" fn process(...)` — the host looks up the zero-arg `process` symbol; the legacy 5-arg shape is gone.
            - Persistent state across blocks goes in **`persist!(NAME: T = init);`** (scalars + Copy coefficient structs read-only in the render loop — envelope levels, write counters, `BiquadCoeffs` recomputed on param change — access via `NAME.get()` / `NAME.set(v)` / `NAME.replace(v)`) or **`persist_mut!(NAME: T = init);`** (DSP blocks mutated per sample via `&mut self` methods like `Biquad::process_sample`, `Lfo::tick`, `DelayLine::write`, plus raw buffers written linearly per block — access in-place via `NAME.with_mut(|val| …)` so the closure body can call `&mut self` methods directly without a get/set round-trip). Both eliminate the `unsafe` blocks the previous `static mut` idiom required.
            - For LFO modulation, prefer building one full buffer of values per block — call `lfo.init(ctx.sample_rate() as f64, ctx.param(RATE) as f64)` once on the snapshot, then iterate. Both `init` args are f64; cast f32 values with `as f64`.
            - Initialize gain/envelope state to `1.0f32` (unity gain), not `0.0`, so the first block isn't silent during smoothing ramp-in.
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

        parts.append("## ConjureDSP API Reference\n\n\(DSPDocumentation.docs(for: lang))")

        parts.append(conventions)

        parts.append("## Output Format\n\n\(outputInstruction)")

        return parts.joined(separator: "\n\n")
    }
}
