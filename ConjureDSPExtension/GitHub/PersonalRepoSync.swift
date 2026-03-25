import Combine
import CommonCrypto
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
    }

    struct SyncResult {
        var pulled: Int = 0
        var pushed: Int = 0
        var conflicts: Int = 0
        var errors: [String] = []
    }

    private let client: GitHubClient
    private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PersonalRepoSync")

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
        var allRemoteSHAs: [String: String] = [:]
        for (subdir, ext) in [("python", "py"), ("rust", "rs")] {
            let files: [GitHubContentsResponse]
            do {
                files = try await client.listContents(owner: owner, repo: repo, path: subdir, token: token)
            } catch {
                // Subdirectory may not exist yet — that's fine
                continue
            }
            // Cache SHAs for ALL files (scripts + metadata) so background ops can update them
            for file in files where file.type == "file" {
                allRemoteSHAs["\(subdir)/\(file.name)"] = file.sha
                if file.name.hasSuffix(".\(ext)") {
                    remotePresets.append((name: file.name, remotePath: "\(subdir)/\(file.name)", sha: file.sha))
                }
            }
        }

        remoteSHAs = allRemoteSHAs

        // Build local file map (filename → URL)
        let localFiles = discoverLocalFiles(in: presetManager.repoPresetsURL)

        let remoteNames = Set(remotePresets.map(\.name))
        let localNames = Set(localFiles.keys)

        // Remote only → pull
        for remote in remotePresets where !localNames.contains(remote.name) {
            do {
                let source = try await client.fetchFileContent(owner: owner, repo: repo, path: remote.remotePath, token: token)
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
                let remoteSource = try await client.fetchFileContent(owner: owner, repo: repo, path: remote.remotePath, token: token)
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

        }

        pendingConflicts.removeAll { $0.id == conflict.id }
        presetManager.refreshPresets()
    }

    // MARK: - Background Push (fire-and-forget after save)

    /// Push a preset script and its sidecar metadata file to the repo.
    /// Skips the write if the remote SHA matches the local content (git blob SHA).
    func backgroundPush(
        filename: String,
        source: String,
        metadata: PresetMetadata?,
        owner: String,
        repo: String,
        token: String
    ) {
        Task.detached { [client, log] in
            do {
                // Compare local content SHA with cached remote SHA to skip unnecessary writes
                let remoteSHA = await MainActor.run { self.remoteSHAs[filename] }
                let localSHA = Self.gitBlobSHA(for: source)
                if let remoteSHA, localSHA == remoteSHA {
                    log.info("Background push skipped (unchanged): \(filename, privacy: .public)")
                    await MainActor.run { self.hasPendingChanges = false }
                } else {
                    let response = try await client.putFile(
                        owner: owner, repo: repo, path: filename,
                        content: source, message: "Update \(filename)",
                        sha: remoteSHA, token: token
                    )
                    await MainActor.run {
                        self.remoteSHAs[filename] = response.content.sha
                        self.hasPendingChanges = false
                    }
                    log.info("Background push: \(filename, privacy: .public)")
                }

                // Push sidecar metadata if provided
                if let metadata {
                    let scriptName = (filename as NSString).lastPathComponent
                    let metadataName = PresetMetadata.metadataFilename(forScript: scriptName)
                    let dir = (filename as NSString).deletingLastPathComponent
                    let metadataPath = dir.isEmpty ? metadataName : "\(dir)/\(metadataName)"
                    if let jsonData = try? metadata.jsonData(),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        let metaSHA = await MainActor.run { self.remoteSHAs[metadataPath] }
                        let metaResponse = try await client.putFile(
                            owner: owner, repo: repo, path: metadataPath,
                            content: jsonString, message: "Update metadata for \(scriptName)",
                            sha: metaSHA, token: token
                        )
                        await MainActor.run {
                            self.remoteSHAs[metadataPath] = metaResponse.content.sha
                        }
                    }
                }
            } catch {
                log.error("Background push failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run { self.hasPendingChanges = true }
            }
        }
    }

    // MARK: - Background Delete (fire-and-forget after delete)

    /// Delete a preset script and its sidecar metadata file from the repo.
    func backgroundDelete(
        filename: String,
        owner: String,
        repo: String,
        token: String
    ) {
        Task.detached { [client, log] in
            // Delete the script file
            do {
                let sha: String
                if let cached = await MainActor.run(body: { self.remoteSHAs[filename] }) {
                    sha = cached
                } else {
                    log.warning("No SHA for \(filename, privacy: .public), fetching...")
                    let file = try await client.getFile(owner: owner, repo: repo, path: filename, token: token)
                    sha = file.sha
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

            // Also delete sidecar metadata
            let scriptName = (filename as NSString).lastPathComponent
            let metadataName = PresetMetadata.metadataFilename(forScript: scriptName)
            let dir = (filename as NSString).deletingLastPathComponent
            let metadataPath = dir.isEmpty ? metadataName : "\(dir)/\(metadataName)"
            do {
                let metaSHA: String
                if let cached = await MainActor.run(body: { self.remoteSHAs[metadataPath] }) {
                    metaSHA = cached
                } else {
                    let file = try await client.getFile(owner: owner, repo: repo, path: metadataPath, token: token)
                    metaSHA = file.sha
                }
                try await client.deleteFile(
                    owner: owner, repo: repo, path: metadataPath,
                    sha: metaSHA, message: "Delete metadata for \(scriptName)", token: token
                )
                await MainActor.run { self.remoteSHAs.removeValue(forKey: metadataPath) }
            } catch {
                // Metadata file may not exist — that's fine
            }
        }
    }

    /// Clear all cached sync state (called on disconnect).
    func reset() {
        remoteSHAs = [:]
        pendingConflicts = []
        hasPendingChanges = false
        error = nil
    }

    // MARK: - Helpers

    /// Compute the git blob SHA1 for a string: SHA1("blob <size>\0<content>").
    /// This matches the SHA that GitHub reports for file contents.
    nonisolated static func gitBlobSHA(for content: String) -> String {
        let data = Data(content.utf8)
        let header = "blob \(data.count)\0"
        var blob = Data(header.utf8)
        blob.append(data)

        // CC_SHA1 via CommonCrypto (available on all Apple platforms)
        var digest = [UInt8](repeating: 0, count: 20)
        blob.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

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
