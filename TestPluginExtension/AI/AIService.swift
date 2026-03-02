import Combine
import Foundation
import os

@MainActor
final class AIService: ObservableObject {
    enum GenerationState: Equatable {
        case idle
        case generating
        case error(String)
    }

    @Published private(set) var state: GenerationState = .idle

    @Published var selectedProviderName: String {
        didSet { UserDefaults.standard.set(selectedProviderName, forKey: "ai.provider") }
    }

    private var currentTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.MichaelJancsy.TestPlugin", category: "AIService")

    let providers: [AIProvider]

    var selectedProvider: AIProvider {
        providers.first { $0.name == selectedProviderName } ?? providers[0]
    }

    var isGenerating: Bool {
        state == .generating
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

    // MARK: - Generation

    /// Generate a script from a natural language prompt. Streams text chunks via onUpdate.
    func generate(
        prompt: String, existingScript: String?,
        onUpdate: @Sendable @escaping (String) -> Void
    ) {
        cancel()

        guard let key = apiKey(for: selectedProvider) else {
            state = .error(AIProviderError.noAPIKey.localizedDescription)
            return
        }

        state = .generating
        log.info("Starting script generation")

        currentTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""

            do {
                let stream = self.selectedProvider.generateScript(
                    prompt: prompt, existingScript: existingScript, apiKey: key
                )
                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    accumulated += chunk
                    await MainActor.run { onUpdate(accumulated) }
                }
                if !Task.isCancelled {
                    self.log.info("Script generation complete (\(accumulated.count) chars)")
                    self.state = .idle
                }
            } catch is CancellationError {
                self.state = .idle
            } catch let error as AIProviderError where error.localizedDescription
                == AIProviderError.cancelled.localizedDescription
            {
                self.state = .idle
            } catch {
                self.log.error("Script generation failed: \(error.localizedDescription)")
                self.state = .error(error.localizedDescription)
            }
        }
    }

    /// Fix a broken script given the error message. Streams text chunks via onUpdate.
    func fix(
        script: String, error: String,
        onUpdate: @Sendable @escaping (String) -> Void
    ) {
        cancel()

        guard let key = apiKey(for: selectedProvider) else {
            state = .error(AIProviderError.noAPIKey.localizedDescription)
            return
        }

        state = .generating
        log.info("Starting script fix")

        currentTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""

            do {
                let stream = self.selectedProvider.fixScript(
                    script: script, error: error, apiKey: key
                )
                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    accumulated += chunk
                    await MainActor.run { onUpdate(accumulated) }
                }
                if !Task.isCancelled {
                    self.log.info("Script fix complete (\(accumulated.count) chars)")
                    self.state = .idle
                }
            } catch is CancellationError {
                self.state = .idle
            } catch let error as AIProviderError where error.localizedDescription
                == AIProviderError.cancelled.localizedDescription
            {
                self.state = .idle
            } catch {
                self.log.error("Script fix failed: \(error.localizedDescription)")
                self.state = .error(error.localizedDescription)
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        if isGenerating { state = .idle }
    }
}
