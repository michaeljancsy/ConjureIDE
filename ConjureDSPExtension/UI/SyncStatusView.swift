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
            if !gitHubService.personalSync.pendingConflicts.isEmpty ||
               !gitHubService.personalSync.pendingBundleConflicts.isEmpty {
                Divider()
                Text("Conflicts")
                    .font(.subheadline.bold())

                ForEach(gitHubService.personalSync.pendingConflicts) { conflict in
                    conflictRow(conflict)
                }
                ForEach(gitHubService.personalSync.pendingBundleConflicts) { conflict in
                    bundleConflictRow(conflict)
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
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func bundleConflictRow(_ conflict: PersonalRepoSync.BundleConflict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(conflict.bundleName).cdp")
                .font(.system(size: 12, weight: .medium, design: .monospaced))

            // Summary of what differs. Full path list lives in the help
            // tooltip so the row stays compact.
            Text(bundleConflictSummary(conflict))
                .font(.caption)
                .foregroundColor(.secondary)
                .help(conflict.differingPaths
                    .map { "\($0.relativePath) (\(describe($0.kind)))" }
                    .joined(separator: "\n"))

            HStack(spacing: 8) {
                Button("Keep Local") {
                    resolveBundleConflict(conflict, resolution: .keepLocal)
                }
                .font(.caption)

                Button("Keep Remote") {
                    resolveBundleConflict(conflict, resolution: .keepRemote)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func bundleConflictSummary(_ conflict: PersonalRepoSync.BundleConflict) -> String {
        let paths = conflict.differingPaths
        let total = paths.count
        if total == 1 {
            return "1 file differs (\(paths[0].relativePath))"
        }
        let changed = paths.filter { $0.kind == .contentDiffers }.count
        let added = paths.filter { $0.kind == .localOnly }.count
        let removed = paths.filter { $0.kind == .remoteOnly }.count
        var parts: [String] = []
        if changed > 0 { parts.append("\(changed) changed") }
        if added > 0 { parts.append("\(added) local-only") }
        if removed > 0 { parts.append("\(removed) remote-only") }
        return "\(total) files differ — \(parts.joined(separator: ", "))"
    }

    private func describe(_ kind: PersonalRepoSync.BundleConflict.DifferingPath.Kind) -> String {
        switch kind {
        case .localOnly: return "local only"
        case .remoteOnly: return "remote only"
        case .contentDiffers: return "content differs"
        }
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

    private func resolveBundleConflict(_ conflict: PersonalRepoSync.BundleConflict, resolution: PersonalRepoSync.ConflictResolution) {
        Task {
            await gitHubService.personalSync.resolveBundleConflict(
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
