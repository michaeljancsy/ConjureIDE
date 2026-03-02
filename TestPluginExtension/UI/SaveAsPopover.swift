import SwiftUI

/// Popover for naming and saving a new preset.
struct SaveAsPopover: View {
    @Binding var name: String
    let existingNames: Set<String>
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var showOverwriteConfirm = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var nameConflict: Bool {
        existingNames.contains(trimmedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Preset As")
                .font(.headline)

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200)
                .accessibilityIdentifier("presetNameField")
                .onSubmit {
                    attemptSave()
                }

            if nameConflict {
                Text("A preset named \"\(trimmedName)\" already exists.")
                    .font(.caption)
                    .foregroundColor(.orange)
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
        .frame(minWidth: 260)
    }

    private func attemptSave() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName)
    }
}
