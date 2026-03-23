import SwiftUI

/// Sync status and conflict resolution for the personal GitHub preset repo.
struct SyncStatusView: View {
    @ObservedObject var gitHubService: GitHubService
    let presetManager: PresetManager
    let onPresetInstalled: (Preset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sync")
                    .font(.headline)
                Spacer()
                if gitHubService.personalSync.isSyncing {
                    ProgressView().controlSize(.small)
                }
            }

            // Status
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

            if gitHubService.personalSync.hasPendingChanges {
                Label("Unsynced changes — will retry on next sync", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Manual sync button
            Button(action: {
                gitHubService.syncIfConnected(presetManager: presetManager)
            }) {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(gitHubService.personalSync.isSyncing)

            // Conflicts
            if !gitHubService.personalSync.pendingConflicts.isEmpty {
                Divider()
                Text("Conflicts")
                    .font(.subheadline.bold())

                ForEach(gitHubService.personalSync.pendingConflicts) { conflict in
                    conflictRow(conflict)
                }
            }

            // Errors
            if let error = gitHubService.personalSync.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .frame(minWidth: 320)
    }

    @ViewBuilder
    private func conflictRow(_ conflict: PersonalRepoSync.SyncConflict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conflict.filename)
                .font(.system(size: 12, weight: .medium, design: .monospaced))

            Text("Local and remote versions differ")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button("Keep Local") {
                    resolveConflict(conflict, resolution: .keepLocal)
                }
                .font(.caption)

                Button("Keep Remote") {
                    resolveConflict(conflict, resolution: .keepRemote)
                }
                .font(.caption)

                Button("Keep Both") {
                    resolveConflict(conflict, resolution: .keepBoth)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func resolveConflict(_ conflict: PersonalRepoSync.SyncConflict, resolution: PersonalRepoSync.ConflictResolution) {
        Task {
            await gitHubService.personalSync.resolveConflict(
                conflict,
                resolution: resolution,
                owner: gitHubService.personalRepoOwner,
                repo: gitHubService.personalRepoName,
                token: gitHubService.token ?? "",
                presetManager: presetManager
            )
        }
    }
}
