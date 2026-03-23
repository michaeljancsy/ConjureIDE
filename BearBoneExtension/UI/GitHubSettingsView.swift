import SwiftUI

/// Settings view for GitHub PAT and personal repo configuration.
struct GitHubSettingsView: View {
    @ObservedObject var gitHubService: GitHubService
    let onDone: () -> Void

    @State private var tokenInput = ""
    @State private var showToken = false
    @State private var ownerInput = ""
    @State private var repoInput = ""
    @State private var testStatus: TestStatus = .idle

    private enum TestStatus {
        case idle, testing, success, failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub Settings")
                .font(.headline)

            // Token
            Text("Personal Access Token")
                .font(.subheadline.bold())

            HStack {
                if showToken {
                    TextField("ghp_\u{2026}", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("ghp_\u{2026}", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                }
                Button(action: { showToken.toggle() }) {
                    Image(systemName: showToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            Text("Required for syncing presets. Create at GitHub \u{2192} Settings \u{2192} Developer settings \u{2192} Fine-grained tokens with \"Contents\" read/write permission.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                if gitHubService.hasToken {
                    Button("Clear Token") {
                        gitHubService.setToken(nil)
                        tokenInput = ""
                    }
                    .foregroundColor(.red)
                }
                Button("Save Token") {
                    let trimmed = tokenInput.trimmingCharacters(in: .whitespaces)
                    gitHubService.setToken(trimmed.isEmpty ? nil : trimmed)
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            // Personal repo
            Text("Personal Preset Repo")
                .font(.subheadline.bold())

            HStack(spacing: 4) {
                TextField("owner", text: $ownerInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Text("/")
                    .foregroundColor(.secondary)
                TextField("repo", text: $repoInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }

            Text("Your GitHub repo for syncing presets across machines. Preset files (.py/.rs) at the repo root.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                // Test connection
                Button("Test Connection") { testConnection() }
                    .disabled(!canTest)

                switch testStatus {
                case .idle:
                    EmptyView()
                case .testing:
                    ProgressView().controlSize(.small)
                case .success:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                case .failed(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }

                Spacer()

                Button("Save Repo") {
                    gitHubService.personalRepoOwner = ownerInput.trimmingCharacters(in: .whitespaces)
                    gitHubService.personalRepoName = repoInput.trimmingCharacters(in: .whitespaces)
                    onDone()
                }
            }
        }
        .padding()
        .frame(minWidth: 340)
        .onAppear {
            if let existing = gitHubService.token {
                tokenInput = existing
            }
            ownerInput = gitHubService.personalRepoOwner
            repoInput = gitHubService.personalRepoName
        }
    }

    private var canTest: Bool {
        !ownerInput.trimmingCharacters(in: .whitespaces).isEmpty
            && !repoInput.trimmingCharacters(in: .whitespaces).isEmpty
            && gitHubService.hasToken
    }

    private func testConnection() {
        let owner = ownerInput.trimmingCharacters(in: .whitespaces)
        let repo = repoInput.trimmingCharacters(in: .whitespaces)
        guard let token = gitHubService.token else { return }

        testStatus = .testing
        Task {
            do {
                let contents = try await gitHubService.client.listContents(
                    owner: owner, repo: repo, token: token
                )
                let presetCount = contents.filter { $0.name.hasSuffix(".py") || $0.name.hasSuffix(".rs") }.count
                testStatus = .success
            } catch {
                testStatus = .failed(error.localizedDescription)
            }
        }
    }
}
