import SwiftUI

/// Popover for renaming a preset.
struct RenamePopover: View {
    @Binding var name: String
    let currentName: String
    let existingNames: Set<String>
    let onRename: (String) -> Void
    let onCancel: () -> Void

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var nameConflict: Bool {
        trimmedName != currentName && existingNames.contains(trimmedName)
    }

    private var isUnchanged: Bool {
        trimmedName == currentName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Preset")
                .font(.headline)

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200)
                .accessibilityIdentifier("renamePresetField")
                .onSubmit {
                    attemptRename()
                }

            if nameConflict {
                Text("A preset named \"\(trimmedName)\" already exists.")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    attemptRename()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || nameConflict || isUnchanged)
                .accessibilityIdentifier("confirmRenameButton")
            }
        }
        .padding()
        .frame(minWidth: 260)
    }

    private func attemptRename() {
        guard !trimmedName.isEmpty, !nameConflict, !isUnchanged else { return }
        onRename(trimmedName)
    }
}
