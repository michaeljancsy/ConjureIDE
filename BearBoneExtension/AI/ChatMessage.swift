import Foundation

/// A single content block within an API message. Maps to Anthropic's content block types.
enum ContentBlock: Equatable {
    /// Plain text from user or assistant.
    case text(String)
    /// A tool call from the assistant.
    case toolUse(id: String, name: String, input: [String: Any])
    /// The result of executing a tool, sent back as user content.
    case toolResult(toolUseId: String, content: String, isError: Bool)

    static func == (lhs: ContentBlock, rhs: ContentBlock) -> Bool {
        switch (lhs, rhs) {
        case (.text(let a), .text(let b)):
            return a == b
        case (.toolUse(let idA, let nameA, _), .toolUse(let idB, let nameB, _)):
            return idA == idB && nameA == nameB
        case (.toolResult(let idA, let contentA, let errA), .toolResult(let idB, let contentB, let errB)):
            return idA == idB && contentA == contentB && errA == errB
        default:
            return false
        }
    }
}

/// Role in the conversation.
enum MessageRole: String {
    case user
    case assistant
}

/// A message in the conversation, containing one or more content blocks.
struct ChatMessage: Identifiable {
    let id: UUID
    let role: MessageRole
    var content: [ContentBlock]
    let timestamp: Date

    init(role: MessageRole, content: [ContentBlock], id: UUID = UUID(), timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    /// Convenience: create a user text message.
    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: [.text(text)])
    }

    /// Convenience: create an assistant text message.
    static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: [.text(text)])
    }

    /// Convenience: create a user message containing tool results.
    static func toolResults(_ results: [(toolUseId: String, content: String, isError: Bool)]) -> ChatMessage {
        ChatMessage(role: .user, content: results.map { .toolResult(toolUseId: $0.toolUseId, content: $0.content, isError: $0.isError) })
    }

    /// The concatenated text from all text blocks.
    var textContent: String {
        content.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined()
    }

    /// All tool use blocks in this message.
    var toolUseBlocks: [(id: String, name: String, input: [String: Any])] {
        content.compactMap { block in
            if case .toolUse(let id, let name, let input) = block {
                return (id, name, input)
            }
            return nil
        }
    }

    /// Whether this message contains any tool use blocks.
    var hasToolUse: Bool {
        content.contains { block in
            if case .toolUse = block { return true }
            return false
        }
    }
}

/// Serializes conversation messages to the Anthropic API format.
enum MessageSerializer {
    /// Convert a ChatMessage to the Anthropic API message format.
    static func toAPI(_ message: ChatMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": message.role.rawValue]

        // Single text block can use string shorthand
        if message.content.count == 1, case .text(let text) = message.content[0] {
            dict["content"] = text
            return dict
        }

        // Multiple blocks use array format
        dict["content"] = message.content.map { block -> [String: Any] in
            switch block {
            case .text(let text):
                return ["type": "text", "text": text]
            case .toolUse(let id, let name, let input):
                return ["type": "tool_use", "id": id, "name": name, "input": input]
            case .toolResult(let toolUseId, let content, let isError):
                var result: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": toolUseId,
                    "content": content,
                ]
                if isError {
                    result["is_error"] = true
                }
                return result
            }
        }

        return dict
    }

    /// Convert an array of ChatMessages to API format.
    static func toAPI(_ messages: [ChatMessage]) -> [[String: Any]] {
        messages.map { toAPI($0) }
    }
}
