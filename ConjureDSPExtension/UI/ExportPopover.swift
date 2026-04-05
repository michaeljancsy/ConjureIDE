import SwiftUI

enum ExportResult {
    case idle
    case exporting
    case success(String)
    case error(String)
}

/// Popover for configuring and triggering a preset export.
struct ExportPopover: View {
    enum NamCertification: Hashable {
        case permissionGranted
        case personalUseOnly
    }

    @Binding var exportName: String
    let language: ScriptLanguage
    let isLicensed: Bool
    let containsNamTone: Bool
    let onExport: (String) -> Void
    let onCancel: () -> Void

    @State private var namCertification: NamCertification? = nil

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

            if containsNamTone {
                namCertificationSection
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    namCertification = nil
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Export") {
                    attemptExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    exportName.trimmingCharacters(in: .whitespaces).isEmpty
                        || !isLicensed
                        || (containsNamTone && namCertification == nil)
                )
                .accessibilityIdentifier("confirmExportButton")
            }
        }
        .padding()
        .frame(minWidth: 320)
    }

    @ViewBuilder
    private var namCertificationSection: some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Text("This preset contains a NAM tone file that will be bundled into the exported AU. Please certify one of the following:")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            radioOption(
                title: "I have permission from the tone creator to redistribute this file.",
                value: .permissionGranted,
                identifier: "namCertifyPermission"
            )
            radioOption(
                title: "I am exporting for personal use only.",
                value: .personalUseOnly,
                identifier: "namCertifyPersonalUse"
            )
        }
    }

    private func radioOption(title: String, value: NamCertification, identifier: String) -> some View {
        Button(action: { namCertification = value }) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: namCertification == value ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(namCertification == value ? .accentColor : .secondary)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func attemptExport() {
        let trimmed = exportName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, isLicensed else { return }
        if containsNamTone && namCertification == nil { return }
        onExport(trimmed)
    }
}
