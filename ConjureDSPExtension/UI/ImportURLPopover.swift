import SwiftUI

/// Import a preset from any HTTPS URL (GitHub raw, Gist raw, etc.).
struct ImportURLPopover: View {
    let presetManager: PresetManager
    let client: GitHubClient
    let onImported: (Preset) -> Void
    let onCancel: () -> Void

    @State private var urlString = ""
    @State private var previewSource: String?
    @State private var detectedName = ""
    @State private var detectedLanguage: ScriptLanguage = .python
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from URL")
                .font(.headline)

            // URL input
            HStack {
                TextField("https://\u{2026}", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("importURLField")
                    .onSubmit { fetchPreview() }

                Button("Fetch") { fetchPreview() }
                    .disabled(urlString.isEmpty || isLoading)
                    .accessibilityIdentifier("importFetchButton")
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Preview
            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Fetching\u{2026}")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let source = previewSource {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Preset name", text: $detectedName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("importPresetNameField")
                            .frame(width: 180)
                        Text(detectedLanguage == .rust ? "Rust" : "Python")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                    }

                    ScrollView {
                        Text(source)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(height: 160)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(4)
                }
            }

            // Actions
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("importCancelButton")
                if previewSource != nil {
                    Button("Import") { importPreset() }
                        .disabled(detectedName.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 420)
    }

    // MARK: - Actions

    private func fetchPreview() {
        // Upgrade http to https (ATS blocks plaintext HTTP)
        var normalized = urlString
        if normalized.lowercased().hasPrefix("http://") {
            normalized = "https://" + normalized.dropFirst("http://".count)
        }
        guard let url = URL(string: normalized), url.scheme == "https" else {
            error = "Enter a valid URL"
            return
        }

        error = nil
        previewSource = nil

        // Catch known non-file URLs before fetching
        if let validationError = GitHubClient.validateImportURL(url) {
            error = validationError
            return
        }

        isLoading = true

        Task {
            do {
                let (source, responseURL) = try await client.fetchURLWithResponseURL(url)
                let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.hasPrefix("<!doctype") || trimmed.hasPrefix("<html") {
                    self.error = "URL returned a web page. Link to a .py or .rs file."
                } else {
                    // Derive name and language from the final URL (after redirects)
                    // so gist URLs resolve to the actual filename
                    let filename = responseURL.lastPathComponent
                    let ext = responseURL.pathExtension.lowercased()
                    detectedLanguage = ext == "rs" ? .rust : .python
                    detectedName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                    if detectedName.isEmpty || detectedName == "/" {
                        detectedName = "Imported"
                    }
                    previewSource = source
                }
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func importPreset() {
        guard let source = previewSource, !detectedName.isEmpty else { return }
        let name = presetManager.uniqueName(baseName: detectedName)
        do {
            let preset = try presetManager.saveUserBundle(
                name: name,
                source: source,
                language: detectedLanguage
            )
            onImported(preset)
        } catch {
            self.error = "Failed to save: \(error.localizedDescription)"
        }
    }
}
