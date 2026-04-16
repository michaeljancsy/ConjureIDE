import SwiftUI

/// Small popover anchored to the Save toolbar button that lets the user type
/// a commit message. Only shown when `PresetGitCoordinator.mode` is
/// `.alwaysPrompt` — the overwrite-save flow uses this in place of the
/// SaveAsPopover which only appears for Save As.
///
/// The "Don't ask again" link flips the coordinator's preference to
/// `.alwaysTimestamp` and submits with whatever was in the field.
struct SaveMessagePopover: View {
    let defaultMessage: String
    let onSave: (_ commitMessage: String) -> Void
    let onDontAskAgain: () -> Void
    let onCancel: () -> Void

    @State private var message: String = ""
    @FocusState private var messageFocused: Bool

    private var effectiveMessage: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultMessage : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save")
                .font(.headline)

            Text("Commit message")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(defaultMessage, text: $message)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
                .focused($messageFocused)
                .accessibilityIdentifier("commitMessageField")
                .onSubmit { onSave(effectiveMessage) }

            HStack {
                Button("Don't ask again — always use timestamp") {
                    onDontAskAgain()
                }
                .buttonStyle(.link)
                .font(.caption)

                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(effectiveMessage) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("confirmCommitMessageButton")
            }
        }
        .padding()
        .onAppear {
            if message.isEmpty { message = defaultMessage }
            messageFocused = true
        }
    }
}
