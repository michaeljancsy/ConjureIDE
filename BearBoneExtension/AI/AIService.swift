import Combine
import Foundation
import os

/// Manages AI provider selection and API key storage.
@MainActor
final class AIService: ObservableObject {
    @Published var selectedProviderName: String {
        didSet { UserDefaults.standard.set(selectedProviderName, forKey: "ai.provider") }
    }

    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "AIService")

    let providers: [AIProvider]

    var selectedProvider: AIProvider {
        providers.first { $0.name == selectedProviderName } ?? providers[0]
    }

    init(providers: [AIProvider]? = nil) {
        self.providers = providers ?? [AnthropicProvider()]
        self.selectedProviderName =
            UserDefaults.standard.string(forKey: "ai.provider") ?? "Anthropic"
    }

    // MARK: - API Key Management

    func apiKey(for provider: AIProvider) -> String? {
        KeychainHelper.load(key: "apiKey.\(provider.name)")
    }

    func setAPIKey(_ key: String?, for provider: AIProvider) {
        if let key, !key.isEmpty {
            try? KeychainHelper.save(key: "apiKey.\(provider.name)", value: key)
        } else {
            KeychainHelper.delete(key: "apiKey.\(provider.name)")
        }
        objectWillChange.send()
    }

    var hasAPIKey: Bool {
        apiKey(for: selectedProvider) != nil
    }
}
