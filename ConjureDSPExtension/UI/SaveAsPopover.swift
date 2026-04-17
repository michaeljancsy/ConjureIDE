import SwiftUI

/// Popover for naming and saving a new preset.
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
    /// Initial value for the `[ Sliders | Custom UI ]` segmented control.
    /// Callers typically seed this from the source preset's `hasCustomUI`
    /// so Save As "copies" the UI mode the user is looking at, not a
    /// surprising default.
    let defaultIncludeCustomUI: Bool
    /// Called with the chosen name, optional commit message (nil = use
    /// default), and whether to scaffold a starter `ui/index.html` into the
    /// new bundle.
    let onSave: (_ name: String, _ commitMessage: String?, _ includeCustomUI: Bool) -> Void
    let onDontAskAgain: () -> Void
    let onCancel: () -> Void

    @State private var commitMessage: String = ""
    @State private var userEditedMessage: Bool = false
    /// Local mirror of `defaultIncludeCustomUI`, seeded in `.onAppear`. Held
    /// here so switching the segmented control doesn't re-read the default
    /// every render.
    @State private var includeCustomUI: Bool = false

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

            // Segmented UI picker: slider panel (default for most presets)
            // vs. a starter custom HTML/JS UI. Pre-seeded from the source
            // preset's hasCustomUI so duplicating a custom-UI bundle lands
            // on Custom UI, and plain DSP presets stay on Sliders.
            Picker("UI", selection: $includeCustomUI) {
                Text("Sliders").tag(false)
                Text("Custom UI").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("saveAsUIPicker")
            .help("Sliders = use the generated parameter panel. Custom UI = add a starter HTML/JS UI you can edit.")

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
        .onAppear {
            includeCustomUI = defaultIncludeCustomUI
        }
    }

    private func attemptSave() {
        guard !trimmedName.isEmpty else { return }
        let trimmedMsg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // nil if user didn't enter anything — caller substitutes the default
        let messageParam: String? = trimmedMsg.isEmpty ? nil : trimmedMsg
        onSave(trimmedName, messageParam, includeCustomUI)
    }
}
