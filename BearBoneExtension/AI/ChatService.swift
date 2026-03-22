import Combine
import Foundation
import os

/// Manages multi-turn chat conversations with tool use.
/// Runs the agentic loop: send message → receive response → execute tools → send results → repeat.
@MainActor
final class ChatService: ObservableObject {
    enum State: Equatable {
        case idle
        case thinking       // Waiting for initial API response
        case streaming      // Receiving text or tool calls
        case executingTool  // Running a tool locally
        case error(String)
    }

    /// Maximum number of consecutive tool-use rounds before forcing a text response.
    private static let maxToolRounds = 10

    @Published private(set) var state: State = .idle
    @Published private(set) var messages: [ChatMessage] = []

    /// The name of the tool currently being executed (for UI display).
    @Published private(set) var activeToolName: String?

    let toolExecutor: ToolExecutor

    private let provider: AnthropicProvider
    private let aiService: AIService  // For API key access
    private var currentTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "ChatService")

    init(provider: AnthropicProvider? = nil, aiService: AIService) {
        self.provider = provider ?? (aiService.selectedProvider as? AnthropicProvider) ?? AnthropicProvider()
        self.aiService = aiService
        self.toolExecutor = ToolExecutor()
    }

    var isActive: Bool {
        state != .idle && state != .error("")
    }

    // MARK: - Public API

    /// Send a user message and run the agentic loop.
    func send(_ text: String) {
        cancel()

        guard let apiKey = aiService.apiKey(for: aiService.selectedProvider) else {
            state = .error(AIProviderError.noAPIKey.localizedDescription)
            return
        }

        let userMessage = ChatMessage.user(text)
        messages.append(userMessage)
        state = .thinking

        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.runAgentLoop(apiKey: apiKey)
        }
    }

    /// Clear the conversation and start fresh.
    func clearConversation() {
        cancel()
        messages.removeAll()
        state = .idle
    }

    /// Cancel the current request.
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        if state != .idle {
            state = .idle
        }
        activeToolName = nil
    }

    // MARK: - Agentic Loop

    /// Build the system prompt, including the currently loaded script as context.
    private func buildSystemPrompt() -> String {
        var prompt = AnthropicProvider.chatSystemPrompt

        if let au = toolExecutor.audioUnit, let source = au.scriptSource {
            let language = au.currentScriptLanguage.rawValue
            prompt += """

                The currently loaded \(language) script is:
                ```
                \(source)
                ```
                """
        }

        return prompt
    }

    private func runAgentLoop(apiKey: String) async {
        var toolRounds = 0
        let systemPrompt = buildSystemPrompt()

        while !Task.isCancelled && toolRounds < Self.maxToolRounds {
            // Build API messages from conversation
            let apiMessages = MessageSerializer.toAPI(messages)

            // Stream the response
            let stream = provider.streamChat(
                messages: apiMessages,
                tools: ChatTools.definitions,
                systemPrompt: systemPrompt,
                apiKey: apiKey
            )

            // Collect the response (streams into messages array live)
            let messageIndex: Int
            do {
                messageIndex = try await collectStreamedResponse(stream)
            } catch is CancellationError {
                state = .idle
                return
            } catch let error as AIProviderError where error.localizedDescription
                == AIProviderError.cancelled.localizedDescription
            {
                state = .idle
                return
            } catch {
                log.error("Chat error: \(error.localizedDescription)")
                state = .error(error.localizedDescription)
                return
            }

            let assistantMessage = messages[messageIndex]

            // If no tool calls, we're done
            let toolUses = assistantMessage.toolUseBlocks
            if toolUses.isEmpty {
                state = .idle
                activeToolName = nil
                return
            }

            // Execute tools
            state = .executingTool
            var toolResults: [(toolUseId: String, content: String, isError: Bool)] = []

            for toolUse in toolUses {
                if Task.isCancelled { break }
                activeToolName = toolUse.name
                let result = await toolExecutor.execute(name: toolUse.name, input: toolUse.input)
                toolResults.append((toolUseId: toolUse.id, content: result.content, isError: result.isError))
            }

            activeToolName = nil

            if Task.isCancelled {
                state = .idle
                return
            }

            // Append tool results as a user message and loop
            messages.append(ChatMessage.toolResults(toolResults))
            toolRounds += 1
            state = .thinking
        }

        // If we hit the max rounds, the last assistant message is already in the conversation
        if toolRounds >= Self.maxToolRounds {
            log.warning("Hit maximum tool rounds (\(Self.maxToolRounds))")
        }
        state = .idle
        activeToolName = nil
    }

    /// Collect a streamed response, updating the messages array live as text arrives.
    /// Returns the index of the assistant message in the messages array.
    private func collectStreamedResponse(
        _ stream: AsyncThrowingStream<AnthropicProvider.ChatEvent, Error>
    ) async throws -> Int {
        var contentBlocks: [ContentBlock] = []
        var currentText = ""
        var currentToolId: String?
        var currentToolName: String?
        var currentToolInputJSON = ""

        // Create the assistant message upfront so streaming updates it in-place
        let messageId = UUID()
        let placeholder = ChatMessage(role: .assistant, content: [], id: messageId)
        messages.append(placeholder)
        let messageIndex = messages.count - 1

        state = .streaming

        for try await event in stream {
            if Task.isCancelled { throw CancellationError() }

            switch event {
            case .textDelta(let text):
                currentText += text
                // Update message in-place for live streaming
                var preview = contentBlocks
                preview.append(.text(currentText))
                messages[messageIndex] = ChatMessage(
                    role: .assistant, content: preview, id: messageId
                )

            case .toolUseStart(let id, let name):
                if !currentText.isEmpty {
                    contentBlocks.append(.text(currentText))
                    currentText = ""
                }
                currentToolId = id
                currentToolName = name
                currentToolInputJSON = ""

            case .toolInputDelta(let json):
                currentToolInputJSON += json

            case .contentBlockEnd:
                if let toolId = currentToolId, let toolName = currentToolName {
                    let input: [String: Any]
                    if let data = currentToolInputJSON.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    {
                        input = parsed
                    } else if currentToolInputJSON.isEmpty {
                        input = [:]
                    } else {
                        log.warning("Failed to parse tool input JSON: \(currentToolInputJSON.prefix(200))")
                        input = [:]
                    }
                    contentBlocks.append(.toolUse(id: toolId, name: toolName, input: input))
                    currentToolId = nil
                    currentToolName = nil
                    currentToolInputJSON = ""
                    // Update message to show tool use block
                    messages[messageIndex] = ChatMessage(
                        role: .assistant, content: contentBlocks, id: messageId
                    )
                }

            case .messageStop:
                if !currentText.isEmpty {
                    contentBlocks.append(.text(currentText))
                    currentText = ""
                }
            }
        }

        // Finalize
        if !currentText.isEmpty {
            contentBlocks.append(.text(currentText))
        }
        messages[messageIndex] = ChatMessage(
            role: .assistant, content: contentBlocks, id: messageId
        )

        return messageIndex
    }
}
