import SwiftUI

/// Push/pull sync controls for the personal GitHub preset repo.
struct SyncStatusView: View {
    @ObservedObject var gitHubService: GitHubService
    let presetManager: PresetManager
    let onPresetInstalled: (Preset) -> Void

    @State private var pullResult: String?
    @State private var pushResult: String?
    @State private var showPullConfirm = false
    @State private var showPushConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sync Presets")
                    .font(.headline)
                Spacer()
                if gitHubService.personalSync.isSyncing {
                    ProgressView().controlSize(.small)
                }
            }

            if !gitHubService.hasToken {
                Label("Add a GitHub token in Settings to sync", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if !gitHubService.hasPersonalRepo {
                Label("Configure a personal repo in Settings to sync", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                HStack {
                    Text("\(gitHubService.personalRepoOwner)/\(gitHubService.personalRepoName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if let date = gitHubService.personalSync.lastSyncDate {
                        Text("Last: \(date, style: .relative) ago")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    // Pull
                    Button(action: { showPullConfirm = true }) {
                        Label("Pull", systemImage: "arrow.down.circle")
                    }
                    .disabled(gitHubService.personalSync.isSyncing)
                    .alert("Pull Presets", isPresented: $showPullConfirm) {
                        Button("Pull", role: .none) { doPull() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Download new presets from GitHub? Existing presets with the same name will be skipped.")
                    }

                    // Push
                    Button(action: { showPushConfirm = true }) {
                        Label("Push", systemImage: "arrow.up.circle")
                    }
                    .disabled(gitHubService.personalSync.isSyncing)
                    .alert("Push Presets", isPresented: $showPushConfirm) {
                        Button("Push", role: .none) { doPush() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Upload all your user presets to GitHub? Existing remote files will be updated.")
                    }

                    Spacer()
                }

                // Result messages
                if let msg = pullResult {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.green)
                }
                if let msg = pushResult {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.green)
                }
                if let error = gitHubService.personalSync.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .padding()
        .frame(minWidth: 300)
    }

    private func doPull() {
        guard let token = gitHubService.token else { return }
        pullResult = nil
        Task {
            do {
                let result = try await gitHubService.personalSync.pull(
                    owner: gitHubService.personalRepoOwner,
                    repo: gitHubService.personalRepoName,
                    token: token,
                    presetManager: presetManager
                )
                var parts: [String] = []
                if !result.installed.isEmpty { parts.append("\(result.installed.count) installed") }
                if !result.skipped.isEmpty { parts.append("\(result.skipped.count) skipped") }
                pullResult = "Pull: \(parts.isEmpty ? "no new presets" : parts.joined(separator: ", "))"
            } catch {
                // Error already set on personalSync
            }
        }
    }

    private func doPush() {
        guard let token = gitHubService.token else { return }
        pushResult = nil
        Task {
            do {
                let result = try await gitHubService.personalSync.push(
                    owner: gitHubService.personalRepoOwner,
                    repo: gitHubService.personalRepoName,
                    token: token,
                    presetManager: presetManager
                )
                var parts: [String] = []
                if result.created > 0 { parts.append("\(result.created) created") }
                if result.updated > 0 { parts.append("\(result.updated) updated") }
                if result.unchanged > 0 { parts.append("\(result.unchanged) unchanged") }
                pushResult = "Push: \(parts.isEmpty ? "nothing to push" : parts.joined(separator: ", "))"
            } catch {
                // Error already set on personalSync
            }
        }
    }
}
