import SwiftUI

/// Popover for entering a natural language prompt to generate a DSP script.
struct GeneratePopover: View {
    @ObservedObject var aiService: AIService
    var language: ScriptLanguage
    @Binding var isPresented: Bool
    let onGenerate: (String) -> Void

    @State private var prompt: String = ""

    private var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty && aiService.hasAPIKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate Script")
                .font(.headline)

            Text("Describe the \(language == .rust ? "Rust" : "Python") audio effect you want:")
                .font(.caption)
                .foregroundColor(.secondary)

            TextEditor(text: $prompt)
                .font(.body)
                .frame(minWidth: 300, minHeight: 60, maxHeight: 120)
                .border(Color.secondary.opacity(0.3), width: 1)
                .accessibilityIdentifier("generatePromptField")

            if !aiService.hasAPIKey {
                Label(
                    "No API key configured. Open Settings first.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Generate") {
                    isPresented = false
                    onGenerate(prompt)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canGenerate)
                .accessibilityIdentifier("confirmGenerateButton")
            }
        }
        .padding()
        .frame(minWidth: 350)
    }
}
