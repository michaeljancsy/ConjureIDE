import SwiftUI

/// Popover for creating a new preset. Unlike the legacy "New Script" button
/// that seeded an in-memory scratchpad, this commits every decision up
/// front — name, language, and UI type — then writes the full `.cdp` bundle
/// to disk and fires a git commit. Rename handles post-facto name regret.
///
/// This removes two UX incoherences at once:
///   1. The old flow asked for a UI type at Save-As time (the *copy* action)
///      but not at New-Script time (the *create* action), so "do I want a
///      custom UI?" landed in the wrong dialog.
///   2. Scratchpad state meant "is this preset saved?" was a live question
///      at every interaction. Now a preset exists on disk from the moment
///      of creation, and Cmd+S is always a commit, never a promote-and-commit.
struct NewPresetPopover: View {
    /// User-preset names already on disk. The OK button is disabled when the
    /// trimmed name collides with one of these — unlike Save As, there's no
    /// "Replace" path; New Preset doesn't overwrite existing bundles.
    let existingNames: Set<String>

    /// Called when the user confirms. Returns an error string on failure
    /// (disk write, git commit, etc.) so the popover can surface it inline
    /// and stay open for another attempt. `nil` means success → popover
    /// closes.
    let onCreate: (_ name: String, _ language: ScriptLanguage, _ includeCustomUI: Bool) -> String?

    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var language: ScriptLanguage = .python
    @State private var includeCustomUI: Bool = false
    @State private var errorMessage: String? = nil

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var nameCollides: Bool {
        existingNames.contains(trimmedName)
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty && !nameCollides
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Preset")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Preset name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 280)
                    .accessibilityIdentifier("newPresetNameField")
                    .onSubmit {
                        attemptCreate()
                    }

                // Inline validation. Empty = no banner, just OK disabled —
                // no point yelling at the user before they've had a chance
                // to type. Collision is louder because it's a real conflict.
                if nameCollides {
                    Text("A preset named \"\(trimmedName)\" already exists.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Picker("Language", selection: $language) {
                Text("Python").tag(ScriptLanguage.python)
                Text("Rust").tag(ScriptLanguage.rust)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("newPresetLanguagePicker")

            Picker("UI", selection: $includeCustomUI) {
                Text("Basic UI").tag(false)
                Text("Custom UI").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("newPresetUIPicker")
            .help("Basic UI = parameter panel generated from the script. Custom UI = starter HTML/JS UI you can edit.")

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .accessibilityIdentifier("newPresetErrorMessage")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    attemptCreate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .accessibilityIdentifier("confirmNewPresetButton")
            }
        }
        .padding()
        .frame(minWidth: 300)
    }

    private func attemptCreate() {
        guard canSubmit else { return }
        if let err = onCreate(trimmedName, language, includeCustomUI) {
            errorMessage = err
        } else {
            errorMessage = nil
            // Caller is responsible for dismissing on success (same pattern
            // as SaveAsPopover — keeps the dismiss logic in one place).
        }
    }
}
