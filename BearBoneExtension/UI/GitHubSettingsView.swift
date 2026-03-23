import SwiftUI

/// Settings view for GitHub PAT and repo connection/creation.
struct GitHubSettingsView: View {
    @ObservedObject var gitHubService: GitHubService
    let presetManager: PresetManager
    let onDone: () -> Void

    @State private var tokenInput = ""
    @State private var showToken = false
    @State private var ownerInput = ""
    @State private var repoInput = ""
    @State private var newRepoName = "bearbone-presets"
    @State private var newRepoPrivate = true
    @State private var showConnectFlow = false
    @State private var showCreateFlow = false
    @State private var showMigrationPrompt = false
    @State private var isCreating = false
    @State private var isMigrating = false
    @State private var isConnecting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var userPresetCount: Int {
        presetManager.presets.filter(\.isUser).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub Settings")
                .font(.headline)

            // Token section
            tokenSection

            Divider()

            // Repo section
            if gitHubService.hasPersonalRepo {
                connectedRepoSection
            } else {
                disconnectedRepoSection
            }

            // Status messages
            if let msg = statusMessage {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            if let msg = errorMessage {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .frame(minWidth: 340)
        .onAppear {
            if let existing = gitHubService.token {
                tokenInput = existing
            }
        }
        .alert("Upload Existing Presets?", isPresented: $showMigrationPrompt) {
            Button("Upload All") { migratePresets() }
            Button("Skip") { finishConnect() }
        } message: {
            Text("You have \(userPresetCount) local preset(s). Upload them to your repo so they sync across machines?")
        }
    }

    // MARK: - Token Section

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            Text("Create at GitHub \u{2192} Settings \u{2192} Developer settings \u{2192} Fine-grained tokens. Needs \"Contents\" read/write + \"Administration\" for repo creation.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                if gitHubService.hasToken {
                    Button("Clear") {
                        gitHubService.setToken(nil)
                        tokenInput = ""
                    }
                    .foregroundColor(.red)
                }
                Button("Save Token") {
                    let trimmed = tokenInput.trimmingCharacters(in: .whitespaces)
                    gitHubService.setToken(trimmed.isEmpty ? nil : trimmed)
                }
            }
        }
    }

    // MARK: - Connected Repo

    private var connectedRepoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preset Repo")
                .font(.subheadline.bold())

            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("\(gitHubService.personalRepoOwner)/\(gitHubService.personalRepoName)")
                    .font(.system(size: 13, design: .monospaced))
            }

            if let date = gitHubService.personalSync.lastSyncDate {
                Text("Last synced \(date, style: .relative) ago")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if gitHubService.personalSync.hasPendingChanges {
                Label("Unsynced changes", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("Disconnect") {
                    gitHubService.disconnect()
                    statusMessage = nil
                }
                .foregroundColor(.red)
            }
        }
    }

    // MARK: - Disconnected Repo

    private var disconnectedRepoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preset Repo")
                .font(.subheadline.bold())

            Text("Connect a GitHub repo to sync presets across machines.")
                .font(.caption)
                .foregroundColor(.secondary)

            if showConnectFlow {
                connectExistingFlow
            } else if showCreateFlow {
                createNewFlow
            } else {
                HStack(spacing: 12) {
                    Button("Connect Existing") {
                        showConnectFlow = true
                        showCreateFlow = false
                    }
                    .disabled(!gitHubService.hasToken)

                    Button("Create New Repo") {
                        showCreateFlow = true
                        showConnectFlow = false
                    }
                    .disabled(!gitHubService.hasToken)
                }

                if !gitHubService.hasToken {
                    Text("Save a GitHub token first.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    // MARK: - Connect Existing Flow

    private var connectExistingFlow: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            HStack {
                Button("Cancel") {
                    showConnectFlow = false
                    errorMessage = nil
                }
                Spacer()
                Button("Connect") { connectRepo() }
                    .disabled(ownerInput.isEmpty || repoInput.isEmpty || isConnecting)
            }

            if isConnecting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Connecting\u{2026}")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Create New Flow

    private var createNewFlow: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Repo name", text: $newRepoName)
                .textFieldStyle(.roundedBorder)

            Toggle("Private repo", isOn: $newRepoPrivate)
                .font(.caption)

            HStack {
                Button("Cancel") {
                    showCreateFlow = false
                    errorMessage = nil
                }
                Spacer()
                Button("Create") { createRepo() }
                    .disabled(newRepoName.isEmpty || isCreating)
            }

            if isCreating {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Creating repo\u{2026}")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func connectRepo() {
        let owner = ownerInput.trimmingCharacters(in: .whitespaces)
        let repo = repoInput.trimmingCharacters(in: .whitespaces)
        isConnecting = true
        errorMessage = nil

        Task {
            do {
                // Validate by checking for bearbone.json marker
                try await gitHubService.validateRepo(owner: owner, repo: repo)
                gitHubService.personalRepoOwner = owner
                gitHubService.personalRepoName = repo
                showConnectFlow = false
                isConnecting = false

                if userPresetCount > 0 {
                    showMigrationPrompt = true
                } else {
                    finishConnect()
                }
            } catch {
                errorMessage = error.localizedDescription
                isConnecting = false
            }
        }
    }

    private func createRepo() {
        isCreating = true
        errorMessage = nil

        Task {
            do {
                try await gitHubService.createPresetRepo(
                    name: newRepoName,
                    isPrivate: newRepoPrivate,
                    presetManager: presetManager
                )
                showCreateFlow = false
                isCreating = false
                statusMessage = "Created \(gitHubService.personalRepoOwner)/\(gitHubService.personalRepoName)"

                if userPresetCount > 0 {
                    showMigrationPrompt = true
                } else {
                    finishConnect()
                }
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }

    private func migratePresets() {
        isMigrating = true
        Task {
            do {
                let count = try await gitHubService.migrateUserPresetsToRepo(presetManager: presetManager)
                statusMessage = "Uploaded \(count) preset(s) to repo"
            } catch {
                errorMessage = "Migration failed: \(error.localizedDescription)"
            }
            isMigrating = false
            finishConnect()
        }
    }

    private func finishConnect() {
        gitHubService.syncIfConnected(presetManager: presetManager)
    }
}
