import SwiftUI

/// Chat sidebar for conversational AI interaction with the DSP engine.
struct ChatSidebarView: View {
    @ObservedObject var chatService: ChatService
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("AI Chat")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                if !chatService.messages.isEmpty {
                    Button {
                        chatService.clearConversation()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear conversation")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(chatService.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        // Status indicator
                        if let statusText = statusText {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(statusText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .id("status")
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: chatService.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatService.messages.last?.textContent) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            Divider()

            // Input area
            HStack(spacing: 4) {
                TextField("Ask about DSP...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(1...4)
                    .focused($isInputFocused)
                    .onSubmit {
                        sendMessage()
                    }

                if chatService.state != .idle {
                    Button {
                        chatService.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary.opacity(0.5) : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(8)
        }
        .accessibilityIdentifier("chatSidebar")
    }

    private var statusText: String? {
        switch chatService.state {
        case .thinking:
            return "Thinking..."
        case .streaming:
            return nil // Text is already streaming in
        case .executingTool:
            if let tool = chatService.activeToolName {
                return "Running \(toolDisplayName(tool))..."
            }
            return "Running tool..."
        case .error(let message):
            return message
        case .idle:
            return nil
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        chatService.send(text)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastMessage = chatService.messages.last {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    private func toolDisplayName(_ name: String) -> String {
        switch name {
        case "compile_and_run": return "compile & run"
        case "get_script": return "read script"
        case "get_error": return "read error"
        case "set_parameter": return "set parameter"
        case "get_parameters": return "read parameters"
        case "get_audio_state": return "read audio state"
        case "list_presets": return "list presets"
        case "save_preset": return "save preset"
        case "toggle_bypass": return "toggle bypass"
        default: return name
        }
    }
}

/// A single message bubble in the chat.
private struct MessageBubble: View {
    let message: ChatMessage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(message.content.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    if !text.isEmpty {
                        Text(text)
                            .font(.caption)
                            .textSelection(.enabled)
                            .foregroundColor(message.role == .user ? .primary : .primary)
                    }

                case .toolUse(_, let name, _):
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.fill")
                            .font(.caption2)
                        Text(toolLabel(name))
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .padding(.vertical, 2)

                case .toolResult:
                    // Tool results are internal — not shown in chat UI
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .background(
            message.role == .user
                ? RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12))
                : nil
        )
    }

    private func toolLabel(_ name: String) -> String {
        switch name {
        case "compile_and_run": return "Compiled and loaded script"
        case "get_script": return "Read current script"
        case "get_error": return "Checked for errors"
        case "set_parameter": return "Set parameter"
        case "get_parameters": return "Read parameters"
        case "get_audio_state": return "Read audio state"
        case "list_presets": return "Listed presets"
        case "save_preset": return "Saved preset"
        case "toggle_bypass": return "Toggled bypass"
        default: return "Used \(name)"
        }
    }
}
