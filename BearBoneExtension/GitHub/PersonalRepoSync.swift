import Combine
import Foundation
import os

/// Auto-syncs repo presets with a personal GitHub repo.
/// Background push on save/delete, pull on connect, conflict detection.
@MainActor
class PersonalRepoSync: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published var error: String?
    @Published var hasPendingChanges = false
    @Published var lastSyncDate: Date? {
        didSet {
            if let date = lastSyncDate {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "github.lastSyncTimestamp")
            }
        }
    }

    /// Conflicts detected during sync that need user resolution.
    @Published var pendingConflicts: [SyncConflict] = []

    struct SyncConflict: Identifiable {
        let id = UUID()
        let filename: String
        let language: ScriptLanguage
        let localSource: String
        let remoteSource: String
    }

    enum ConflictResolution {
        case keepLocal
        case keepRemote
        case keepBoth
    }

    struct SyncResult {
        var pulled: Int = 0
        var pushed: Int = 0
        var conflicts: Int = 0
        var errors: [String] = []
    }

    private let client: GitHubClient
    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "PersonalRepoSync")

    /// Cache of remote file SHAs, keyed by filename. Needed for updates and deletes.
    private var remoteSHAs: [String: String] = [:]

    init(client: GitHubClient) {
        self.client = client
        let ts = UserDefaults.standard.double(forKey: "github.lastSyncTimestamp")
        if ts > 0 {
            self.lastSyncDate = Date(timeIntervalSince1970: ts)
        }
    }

    // MARK: - Initial Sync (on connect / launch)

    /// Sync local repo cache with the remote repo. Returns conflicts for user resolution.
    /// Repo structure: `python/*.py` and `rust/*.rs` subdirectories.
    func syncOnConnect(
        owner: String,
        repo: String,
        token: String,
        presetManager: PresetManager
    ) async -> SyncResult {
        isSyncing = true
        error = nil
        defer { isSyncing = false }

        var result = SyncResult()

        // Fetch remote files from both language subdirectories
        var remotePresets: [(name: String, remotePath: String, sha: String)] = []
        for (subdir, ext) in [("python", "py"), ("rust", "rs")] {
            let files: [GitHubContentsResponse]
            do {
                files = try await client.listContents(owner: owner, repo: repo, path: subdir, token: token)
            } catch {
                // Subdirectory may not exist yet — that's fine
                continue
            }
            for file in files where file.type == "file" && file.name.hasSuffix(".\(ext)") {
                remotePresets.append((name: file.name, remotePath: "\(subdir)/\(file.name)", sha: file.sha))
            }
        }

        // Cache remote SHAs keyed by remote path (e.g. "python/my-filter.py")
        remoteSHAs = Dictionary(uniqueKeysWithValues: remotePresets.map { ($0.remotePath, $0.sha) })

        // Build local file map (filename → URL)
        let localFiles = discoverLocalFiles(in: presetManager.repoPresetsURL)

        let remoteNames = Set(remotePresets.map(\.name))
        let localNames = Set(localFiles.keys)

        // Remote only → pull
        for remote in remotePresets where !localNames.contains(remote.name) {
            do {
                let source = try await client.fetchRawFile(owner: owner, repo: repo, path: remote.remotePath)
                let destURL = presetManager.repoPresetsURL.appendingPathComponent(remote.name)
                try source.write(to: destURL, atomically: true, encoding: .utf8)
                result.pulled += 1
            } catch {
                result.errors.append("Pull \(remote.name): \(error.localizedDescription)")
            }
        }

        // Local only → push
        for (filename, localURL) in localFiles where !remoteNames.contains(filename) {
            guard let source = try? String(contentsOf: localURL, encoding: .utf8) else { continue }
            let ext = (filename as NSString).pathExtension
            let subdir = ext == "rs" ? "rust" : "python"
            let remotePath = "\(subdir)/\(filename)"
            do {
                let response = try await client.putFile(
                    owner: owner, repo: repo, path: remotePath,
                    content: source, message: "Add \(filename)", token: token
                )
                remoteSHAs[remotePath] = response.content.sha
                result.pushed += 1
            } catch {
                result.errors.append("Push \(filename): \(error.localizedDescription)")
            }
        }

        // Both exist → check for conflicts
        for remote in remotePresets where localNames.contains(remote.name) {
            guard let localURL = localFiles[remote.name],
                  let localSource = try? String(contentsOf: localURL, encoding: .utf8) else { continue }
            do {
                let remoteSource = try await client.fetchRawFile(owner: owner, repo: repo, path: remote.remotePath)
                if localSource != remoteSource {
                    let ext = (remote.name as NSString).pathExtension
                    let language: ScriptLanguage = ext == "rs" ? .rust : .python
                    pendingConflicts.append(SyncConflict(
                        filename: remote.name,
                        language: language,
                        localSource: localSource,
                        remoteSource: remoteSource
                    ))
                    result.conflicts += 1
                }
            } catch {
                result.errors.append("Compare \(remote.name): \(error.localizedDescription)")
            }
        }

        presetManager.refreshPresets()
        lastSyncDate = Date()
        hasPendingChanges = false

        if !result.errors.isEmpty {
            self.error = "\(result.errors.count) sync error(s)"
        }

        return result
    }

    // MARK: - Conflict Resolution

    /// Resolve a single conflict.
    func resolveConflict(
        _ conflict: SyncConflict,
        resolution: ConflictResolution,
        owner: String,
        repo: String,
        token: String,
        presetManager: PresetManager
    ) async {
        let destURL = presetManager.repoPresetsURL.appendingPathComponent(conflict.filename)

        let subdir = conflict.language == .rust ? "rust" : "python"
        let remotePath = "\(subdir)/\(conflict.filename)"

        switch resolution {
        case .keepLocal:
            // Push local to remote
            do {
                let response = try await client.putFile(
                    owner: owner, repo: repo, path: remotePath,
                    content: conflict.localSource, message: "Update \(conflict.filename)",
                    sha: remoteSHAs[remotePath], token: token
                )
                remoteSHAs[remotePath] = response.content.sha
            } catch {
                log.error("Failed to push conflict resolution: \(error.localizedDescription, privacy: .public)")
            }

        case .keepRemote:
            // Overwrite local with remote
            try? conflict.remoteSource.write(to: destURL, atomically: true, encoding: .utf8)

        case .keepBoth:
            // Keep remote as-is, rename local
            let baseName = (conflict.filename as NSString).deletingPathExtension
            let ext = (conflict.filename as NSString).pathExtension
            let renamedName = "\(baseName) (local).\(ext)"
            let renamedURL = presetManager.repoPresetsURL.appendingPathComponent(renamedName)
            try? conflict.localSource.write(to: renamedURL, atomically: true, encoding: .utf8)
            // Overwrite original with remote
            try? conflict.remoteSource.write(to: destURL, atomically: true, encoding: .utf8)
            // Push the renamed local copy
            Task {
                try? await client.putFile(
                    owner: owner, repo: repo, path: "\(subdir)/\(renamedName)",
                    content: conflict.localSource, message: "Add \(renamedName)", token: token
                )
            }
        }

        pendingConflicts.removeAll { $0.id == conflict.id }
        presetManager.refreshPresets()
    }

    // MARK: - Background Push (fire-and-forget after save)

    func backgroundPush(
        filename: String,
        source: String,
        owner: String,
        repo: String,
        token: String
    ) {
        Task.detached { [client, log] in
            do {
                let sha = await MainActor.run { self.remoteSHAs[filename] }
                let response = try await client.putFile(
                    owner: owner, repo: repo, path: filename,
                    content: source, message: "Update \(filename)",
                    sha: sha, token: token
                )
                await MainActor.run {
                    self.remoteSHAs[filename] = response.content.sha
                    self.hasPendingChanges = false
                }
                log.info("Background push: \(filename, privacy: .public)")
            } catch {
                log.error("Background push failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run { self.hasPendingChanges = true }
            }
        }
    }

    // MARK: - Background Delete (fire-and-forget after delete)

    func backgroundDelete(
        filename: String,
        owner: String,
        repo: String,
        token: String
    ) {
        Task.detached { [client, log] in
            do {
                guard let sha = await MainActor.run(body: { self.remoteSHAs[filename] }) else {
                    log.warning("No SHA for \(filename, privacy: .public), fetching...")
                    let file = try await client.getFile(owner: owner, repo: repo, path: filename, token: token)
                    try await client.deleteFile(
                        owner: owner, repo: repo, path: filename,
                        sha: file.sha, message: "Delete \(filename)", token: token
                    )
                    await MainActor.run { self.remoteSHAs.removeValue(forKey: filename) }
                    return
                }
                try await client.deleteFile(
                    owner: owner, repo: repo, path: filename,
                    sha: sha, message: "Delete \(filename)", token: token
                )
                await MainActor.run { self.remoteSHAs.removeValue(forKey: filename) }
                log.info("Background delete: \(filename, privacy: .public)")
            } catch {
                log.error("Background delete failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run { self.hasPendingChanges = true }
            }
        }
    }

    // MARK: - Helpers

    private func discoverLocalFiles(in directory: URL) -> [String: URL] {
        let supportedExts: Set<String> = ["py", "rs"]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        return Dictionary(uniqueKeysWithValues: files
            .filter { supportedExts.contains($0.pathExtension) }
            .map { ($0.lastPathComponent, $0) }
        )
    }
}
