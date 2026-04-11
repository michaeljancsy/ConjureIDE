import SwiftUI

/// Settings view for GitHub PAT and repo connection/creation.
struct GitHubSettingsView: View {
    @ObservedObject var gitHubService: GitHubService
    let presetManager: PresetManager
    let onDone: () -> Void

    @State private var tokenInput = ""
    @State private var showToken = false
    @State private var repoInput = ""
    @State private var newRepoName = "conjuredsp-presets"
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        .accessibilityIdentifier("githubTokenField")
                } else {
                    SecureField("ghp_\u{2026}", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("githubTokenField")
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
                .accessibilityIdentifier("saveTokenButton")
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

            Text("Saves, edits, and deletes sync automatically to this repo.")
                .font(.caption)
                .foregroundColor(.secondary)

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
                Button("Sync Now") {
                    gitHubService.syncIfConnected(presetManager: presetManager)
                }
                .disabled(gitHubService.personalSync.isSyncing)

                Spacer()

                Button("Disconnect") {
                    gitHubService.disconnect(presetManager: presetManager)
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
                    .accessibilityIdentifier("connectExistingRepoButton")

                    Button("Create New Repo") {
                        showCreateFlow = true
                        showConnectFlow = false
                    }
                    .disabled(!gitHubService.hasToken)
                    .accessibilityIdentifier("createNewRepoButton")
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
            TextField("owner/repo or GitHub URL", text: $repoInput)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    showConnectFlow = false
                    errorMessage = nil
                }
                Spacer()
                Button("Connect") { connectRepo() }
                    .disabled(repoInput.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
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

    /// Parse "owner/repo" from various input formats:
    /// - `owner/repo`
    /// - `https://github.com/owner/repo`
    /// - `https://github.com/owner/repo/...` (with trailing path)
    /// - `github.com/owner/repo`
    private func parseRepoInput(_ input: String) -> (owner: String, repo: String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try as URL first
        if trimmed.contains("github.com") {
            // Normalize: add scheme if missing so URL parsing works
            let urlString = trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"
            if let url = URL(string: urlString) {
                let parts = url.pathComponents.filter { $0 != "/" }
                if parts.count >= 2 {
                    return (parts[0], parts[1])
                }
            }
        }

        // Try as "owner/repo"
        let parts = trimmed.split(separator: "/", maxSplits: 1)
        if parts.count == 2 {
            let owner = String(parts[0])
            let repo = String(parts[1])
            if !owner.isEmpty && !repo.isEmpty {
                return (owner, repo)
            }
        }

        return nil
    }

    private func connectRepo() {
        guard let (owner, repo) = parseRepoInput(repoInput) else {
            errorMessage = "Enter owner/repo or a GitHub URL"
            return
        }
        isConnecting = true
        errorMessage = nil

        Task {
            do {
                try await gitHubService.validateRepo(owner: owner, repo: repo)
                gitHubService.personalRepoOwner = owner
                gitHubService.personalRepoName = repo
                Analytics.track(.githubRepoConnect, properties: [
                    "type": "existing",
                    "owner": owner,
                ])
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
                Analytics.track(.githubRepoConnect, properties: [
                    "type": "new",
                    "owner": gitHubService.personalRepoOwner,
                ])
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
