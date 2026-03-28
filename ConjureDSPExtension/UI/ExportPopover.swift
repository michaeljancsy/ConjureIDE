import SwiftUI

enum ExportResult {
    case idle
    case exporting
    case success(String)
    case error(String)
}

/// Popover for configuring and triggering a preset export.
struct ExportPopover: View {
    @Binding var exportName: String
    let language: ScriptLanguage
    let isLicensed: Bool
    let onExport: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export as Standalone AU")
                .font(.headline)

            TextField("Effect name", text: $exportName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 200)
                .accessibilityIdentifier("exportNameField")
                .onSubmit {
                    attemptExport()
                }

            HStack(spacing: 4) {
                Text("Language:")
                    .foregroundColor(.secondary)
                Text(language == .rust ? "Rust (WASM)" : "Python")
                    .foregroundColor(.secondary)
            }
            .font(.caption)

            if !isLicensed {
                Text("Subscription required to export presets.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Export") {
                    attemptExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(exportName.trimmingCharacters(in: .whitespaces).isEmpty || !isLicensed)
                .accessibilityIdentifier("confirmExportButton")
            }
        }
        .padding()
        .frame(minWidth: 280)
    }

    private func attemptExport() {
        let trimmed = exportName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, isLicensed else { return }
        onExport(trimmed)
    }
}
