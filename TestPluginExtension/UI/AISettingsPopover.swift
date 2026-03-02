import SwiftUI

/// Popover for configuring AI provider and API key.
struct AISettingsPopover: View {
    @ObservedObject var aiService: AIService
    let onDone: () -> Void

    @State private var apiKeyInput: String = ""
    @State private var showKey: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Settings")
                .font(.headline)

            if aiService.providers.count > 1 {
                Picker("Provider", selection: $aiService.selectedProviderName) {
                    ForEach(aiService.providers, id: \.name) { provider in
                        Text(provider.name).tag(provider.name)
                    }
                }
            } else {
                HStack {
                    Text("Provider:")
                    Text(aiService.selectedProvider.name)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            Text("API Key")
                .font(.subheadline.bold())

            HStack {
                if showKey {
                    TextField("sk-ant-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("apiKeyField")
                } else {
                    SecureField("sk-ant-...", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("apiKeyField")
                }
                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Spacer()
                if aiService.hasAPIKey {
                    Button("Clear Key") {
                        aiService.setAPIKey(nil, for: aiService.selectedProvider)
                        apiKeyInput = ""
                    }
                    .foregroundColor(.red)
                }
                Button("Save") {
                    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespaces)
                    aiService.setAPIKey(trimmed.isEmpty ? nil : trimmed, for: aiService.selectedProvider)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("saveAPIKeyButton")
            }
        }
        .padding()
        .frame(minWidth: 300)
        .onAppear {
            if let existing = aiService.apiKey(for: aiService.selectedProvider) {
                apiKeyInput = existing
            }
        }
    }
}
