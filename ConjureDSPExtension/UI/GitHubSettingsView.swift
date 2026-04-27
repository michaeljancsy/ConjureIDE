import SwiftUI

/// Full settings surface for the git-backed preset library. Three sections:
///
///   1. Commit messages — pick `alwaysPrompt` vs `alwaysTimestamp`.
///   2. Personal Access Token — Keychain-backed, only used for pushing.
///   3. Remote sync — set/clear an origin URL, push manually.
///
/// Kept in `GitHubSettingsView.swift` for backward compatibility with the
/// existing toolbar popover site, but the type is `RemoteSyncSettingsView`.
struct RemoteSyncSettingsView: View {
    @ObservedObject var gitHubService: GitHubService
    @Bindable var gitCoordinator: PresetGitCoordinator
    let onDone: () -> Void

    @State private var tokenInput = ""
    @State private var showToken = false

    @State private var remoteURLInput = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    /// Full stderr / diagnostic text for the current errorMessage, when the
    /// failure came from PresetGitCoordinator and carried real detail.
    /// Rendered below the summary in a scrollable block so the user can see
    /// exactly what git complained about instead of staring at "push failed".
    @State private var errorDetails: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preset Sync")
                .font(.headline)

            commitMessageSection

            Divider()

            tokenSection

            Divider()

            remoteSection

            if let msg = statusMessage {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            if let msg = errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.red)
                    if let detail = errorDetails, !detail.isEmpty {
                        ScrollView {
                            Text(detail)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        HStack {
                            Button("Copy error details") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(msg + "\n\n" + detail, forType: .string)
                            }
                            .controlSize(.small)
                            Spacer()
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done", action: onDone)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            tokenInput = gitHubService.token ?? ""
            remoteURLInput = gitCoordinator.remoteURL ?? ""
        }
    }

    // MARK: - Commit messages

    @ViewBuilder
    private var commitMessageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Commit messages")
                .font(.subheadline.bold())

            Picker("", selection: $gitCoordinator.mode) {
                ForEach(CommitMessageMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            HStack {
                Button("Reset to default") {
                    gitCoordinator.resetModeToDefault()
                    statusMessage = "Reset to \"\(CommitMessageMode.defaultMode.displayName)\""
                }
                .buttonStyle(.link)
                .font(.caption)
                Spacer()
            }
        }
    }

    // MARK: - Token

    @ViewBuilder
    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Personal Access Token")
                .font(.subheadline.bold())
            Text("Only used when pushing to a remote. Local commits work without a token.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if showToken {
                    TextField("ghp_...", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("ghp_...", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                }
                Button(action: { showToken.toggle() }) {
                    Image(systemName: showToken ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Button("Save") {
                    gitHubService.setToken(tokenInput)
                    statusMessage = "Token saved"
                    errorMessage = nil
                }
                .disabled(tokenInput.isEmpty || tokenInput == (gitHubService.token ?? ""))

                Button("Clear") {
                    gitHubService.setToken(nil)
                    tokenInput = ""
                    statusMessage = "Token cleared"
                    errorMessage = nil
                }
                .disabled(!gitHubService.hasToken && tokenInput.isEmpty)
            }
        }
    }

    // MARK: - Remote sync

    @ViewBuilder
    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote sync")
                .font(.subheadline.bold())

            if let remote = gitCoordinator.remoteURL, !remote.isEmpty {
                connectedRemote(remote)
            } else {
                disconnectedRemote
            }
        }
    }

    @ViewBuilder
    private func connectedRemote(_ remote: String) -> some View {
        Text(shortenedRemote(remote))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)

        pushStateLabel

        HStack {
            Button("Push now") {
                Task {
                    isWorking = true
                    errorMessage = nil
                    errorDetails = nil
                    let result = await gitCoordinator.pushIfRemoteConfigured()
                    isWorking = false
                    switch result {
                    case .success:
                        statusMessage = "Pushed"
                    case .failure(let e):
                        errorMessage = e.localizedDescription
                        errorDetails = (e as? PresetGitError)?.stderr
                    }
                }
            }
            .disabled(isWorking || !gitHubService.hasToken)

            Button("Clear remote") {
                Task {
                    isWorking = true
                    errorMessage = nil
                    errorDetails = nil
                    let result = await gitCoordinator.clearRemote()
                    isWorking = false
                    remoteURLInput = ""
                    switch result {
                    case .success:
                        statusMessage = "Remote cleared"
                    case .failure(let e):
                        errorMessage = e.localizedDescription
                        errorDetails = (e as? PresetGitError)?.stderr
                    }
                }
            }
            .disabled(isWorking)

            if isWorking { ProgressView().controlSize(.small) }
        }

        if !gitHubService.hasToken {
            Text("Add a Personal Access Token above to enable push.")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var disconnectedRemote: some View {
        Text("No remote configured. Your presets are committed locally only.")
            .font(.caption)
            .foregroundStyle(.secondary)

        TextField("https://github.com/you/conjuredsp-presets.git", text: $remoteURLInput)
            .textFieldStyle(.roundedBorder)

        HStack {
            Button("Set remote") {
                Task {
                    isWorking = true
                    errorMessage = nil
                    errorDetails = nil
                    let result = await gitCoordinator.setRemote(url: remoteURLInput)
                    isWorking = false
                    switch result {
                    case .success:
                        statusMessage = "Remote set"
                    case .failure(let e):
                        errorMessage = e.localizedDescription
                        errorDetails = (e as? PresetGitError)?.stderr
                    }
                }
            }
            .disabled(remoteURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)

            if isWorking { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private var pushStateLabel: some View {
        switch gitCoordinator.lastPushState {
        case .idle:
            Text("Never pushed")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .pushing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Pushing\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ok(let date):
            Text("Last push: \(date, style: .relative) ago")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let msg):
            Text("Push failed: \(msg)")
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(2)
        }
    }

    // MARK: - Helpers

    /// Trim the scheme + token + .git suffix off a remote URL for display.
    private func shortenedRemote(_ url: String) -> String {
        var s = url
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        // Strip basic-auth "user:token@" if present
        if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.hasSuffix(".git") { s = String(s.dropLast(".git".count)) }
        return s
    }
}
