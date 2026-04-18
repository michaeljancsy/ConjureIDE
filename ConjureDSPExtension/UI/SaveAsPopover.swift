import SwiftUI

/// Popover for naming and saving (duplicating) a preset.
///
/// Save As is a "copy this preset with a new name" action — the UI type
/// (Basic UI vs. Custom UI) is inherited from the source bundle, not chosen
/// here. When the user wants a different UI type, `+ Add Custom UI` in the
/// toggle bar flips an existing Basic-UI bundle, or New Preset picks both
/// dimensions up front.
///
/// When `commitMessageMode == .alwaysPrompt`, a commit-message field is shown
/// below the name. An empty message falls back to `defaultCommitMessage(for:)`.
/// In `.alwaysTimestamp` mode the commit-message field is hidden and a
/// timestamp is used automatically.
struct SaveAsPopover: View {
    @Binding var name: String
    let existingNames: Set<String>
    let commitMessageMode: CommitMessageMode
    /// Pre-filled default text for the commit-message field (e.g. "Add <name>").
    let defaultCommitMessagePrefix: String
    /// Called with the chosen name and optional commit message (nil = use
    /// default). The caller forwards the source bundle's `hasCustomUI` into
    /// `PresetManager.savePreset(scaffoldUI:)` — Save As no longer asks.
    let onSave: (_ name: String, _ commitMessage: String?) -> Void
    let onDontAskAgain: () -> Void
    let onCancel: () -> Void

    @State private var commitMessage: String = ""
    @State private var userEditedMessage: Bool = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var nameConflict: Bool {
        existingNames.contains(trimmedName)
    }

    /// What to pre-fill the commit-message field with, based on the current
    /// name. Updates live as the user types, unless they've edited it.
    private var livePlaceholder: String {
        "\(defaultCommitMessagePrefix) \(trimmedName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Preset As")
                .font(.headline)

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
                .accessibilityIdentifier("presetNameField")
                .onSubmit {
                    attemptSave()
                }

            if nameConflict {
                Text("A preset named \"\(trimmedName)\" already exists.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if commitMessageMode == .alwaysPrompt {
                Divider()
                Text("Commit message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(livePlaceholder, text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("commitMessageField")
                    .onChange(of: commitMessage) { _, _ in userEditedMessage = true }

                HStack {
                    Button("Don't ask again — always use timestamp") {
                        // Flip the preference, then attempt the save so the
                        // click isn't a silent no-op. attemptSave guards on
                        // an empty name, so if the user hasn't typed one the
                        // popover stays open for them to finish.
                        onDontAskAgain()
                        attemptSave()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(trimmedName.isEmpty)
                    Spacer()
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(nameConflict ? "Replace" : "Save") {
                    attemptSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
                .accessibilityIdentifier("confirmSaveButton")
            }
        }
        .padding()
        .frame(minWidth: 280)
    }

    private func attemptSave() {
        guard !trimmedName.isEmpty else { return }
        let trimmedMsg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // nil if user didn't enter anything — caller substitutes the default
        let messageParam: String? = trimmedMsg.isEmpty ? nil : trimmedMsg
        onSave(trimmedName, messageParam)
    }
}
