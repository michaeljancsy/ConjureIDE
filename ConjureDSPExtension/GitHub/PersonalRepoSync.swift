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

    /// Bundle-level divergences detected on connect. Surface separately from
    /// single-file conflicts because bundles are a whole directory and the
    /// keep-local/keep-remote semantics replace the entire tree instead of
    /// a single blob's content.
    @Published var pendingBundleConflicts: [BundleConflict] = []

    struct SyncConflict: Identifiable {
        let id = UUID()
        let filename: String
        let language: ScriptLanguage
        let localSource: String
        let remoteSource: String
    }

    /// Divergence between a local bundle directory and its `bundles/<name>/`
    /// tree on the remote. Listed files are those that differ — added,
    /// removed, or content-mismatched. `remoteFiles` is retained so
    /// keep-remote can fetch + write the whole tree without a second Tree
    /// API call.
    struct BundleConflict: Identifiable {
        let id = UUID()
        let bundleName: String
        let localBundleURL: URL
        /// Per-file divergence summary. Empty means the bundles match and
        /// no conflict should have been raised.
        let differingPaths: [DifferingPath]
        let remoteFiles: [GitHubTreeFile]

        struct DifferingPath: Equatable {
            let relativePath: String
            let kind: Kind
            enum Kind { case localOnly, remoteOnly, contentDiffers }
        }
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

        // Pull any remote bundles that don't exist locally yet. This runs
        // after the single-file sync above so the two don't race on
        // `refreshPresets()`. Failures are logged rather than surfaced —
        // the existing file-level sync result remains authoritative.
        await pullBundlesOnConnect(
            owner: owner, repo: repo, token: token, presetManager: presetManager
        )

        presetManager.refreshPresets()
        lastSyncDate = Date()
        hasPendingChanges = false

        if !result.errors.isEmpty {
            self.error = "\(result.errors.count) sync error(s)"
            SentryHelper.capture(
                "GitHub sync completed with errors",
                level: .warning,
                category: "github.sync",
                extra: [
                    "errorCount": result.errors.count,
                    "errors": Array(result.errors.prefix(3)).joined(separator: "; "),
                    "pulled": result.pulled,
                    "pushed": result.pushed,
                    "conflicts": result.conflicts,
                ]
            )
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

    // MARK: - Background Rename (fire-and-forget after rename)

    /// Rename a preset on the repo: push new file, then delete old file.
    /// Order ensures data safety — if push fails, old file remains.
    func backgroundRename(
        oldFilename: String,
        newFilename: String,
        source: String,
        metadata: PresetMetadata?,
        owner: String,
        repo: String,
        token: String
    ) {
        Task.detached { [client, log] in
            do {
                // 1. Push new file (no SHA needed — new path)
                let response = try await client.putFile(
                    owner: owner, repo: repo, path: newFilename,
                    content: source, message: "Rename \((oldFilename as NSString).lastPathComponent) → \((newFilename as NSString).lastPathComponent)",
                    sha: nil, token: token
                )
                await MainActor.run {
                    self.remoteSHAs[newFilename] = response.content.sha
                }
                log.info("Background rename push: \(newFilename, privacy: .public)")

                // Push new sidecar metadata
                if let metadata {
                    let newScriptName = (newFilename as NSString).lastPathComponent
                    let newMetadataName = PresetMetadata.metadataFilename(forScript: newScriptName)
                    let dir = (newFilename as NSString).deletingLastPathComponent
                    let newMetadataPath = dir.isEmpty ? newMetadataName : "\(dir)/\(newMetadataName)"
                    if let jsonData = try? metadata.jsonData(),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        let metaResponse = try await client.putFile(
                            owner: owner, repo: repo, path: newMetadataPath,
                            content: jsonString, message: "Add metadata for \(newScriptName)",
                            sha: nil, token: token
                        )
                        await MainActor.run {
                            self.remoteSHAs[newMetadataPath] = metaResponse.content.sha
                        }
                    }
                }

                // 2. Delete old file
                let oldSHA: String
                if let cached = await MainActor.run(body: { self.remoteSHAs[oldFilename] }) {
                    oldSHA = cached
                } else {
                    log.warning("No SHA for \(oldFilename, privacy: .public), fetching...")
                    let file = try await client.getFile(owner: owner, repo: repo, path: oldFilename, token: token)
                    oldSHA = file.sha
                }
                try await client.deleteFile(
                    owner: owner, repo: repo, path: oldFilename,
                    sha: oldSHA, message: "Delete renamed \((oldFilename as NSString).lastPathComponent)", token: token
                )
                await MainActor.run { self.remoteSHAs.removeValue(forKey: oldFilename) }
                log.info("Background rename delete: \(oldFilename, privacy: .public)")

                // Delete old sidecar metadata
                let oldScriptName = (oldFilename as NSString).lastPathComponent
                let oldMetadataName = PresetMetadata.metadataFilename(forScript: oldScriptName)
                let oldDir = (oldFilename as NSString).deletingLastPathComponent
                let oldMetadataPath = oldDir.isEmpty ? oldMetadataName : "\(oldDir)/\(oldMetadataName)"
                do {
                    let metaSHA: String
                    if let cached = await MainActor.run(body: { self.remoteSHAs[oldMetadataPath] }) {
                        metaSHA = cached
                    } else {
                        let file = try await client.getFile(owner: owner, repo: repo, path: oldMetadataPath, token: token)
                        metaSHA = file.sha
                    }
                    try await client.deleteFile(
                        owner: owner, repo: repo, path: oldMetadataPath,
                        sha: metaSHA, message: "Delete metadata for \(oldScriptName)", token: token
                    )
                    await MainActor.run { self.remoteSHAs.removeValue(forKey: oldMetadataPath) }
                } catch {
                    // Old metadata file may not exist — that's fine
                }

                await MainActor.run { self.hasPendingChanges = false }
            } catch {
                log.error("Background rename failed (\(oldFilename, privacy: .public) → \(newFilename, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                await MainActor.run { self.hasPendingChanges = true }
            }
        }
    }

    /// Compare a local bundle directory against the remote tree entries
    /// under `bundles/<bundleName>/`. Returns an entry for every path that
    /// differs (local-only, remote-only, or content-differs). Empty return
    /// means the bundles are in sync; no conflict should surface.
    nonisolated private static func diffBundle(
        localBundleURL: URL,
        bundleName: String,
        remoteFiles: [GitHubTreeFile]
    ) -> [BundleConflict.DifferingPath] {
        let localFiles = enumerateBundleFiles(at: localBundleURL)
        let localByRelative = Dictionary(uniqueKeysWithValues: localFiles.map { ($0.1, $0.0) })

        let remotePrefix = "\(remoteBundlesPrefix)/\(bundleName)/"
        var remoteByRelative: [String: GitHubTreeFile] = [:]
        for file in remoteFiles where file.path.hasPrefix(remotePrefix) {
            remoteByRelative[String(file.path.dropFirst(remotePrefix.count))] = file
        }

        var diffs: [BundleConflict.DifferingPath] = []
        let allKeys = Set(localByRelative.keys).union(remoteByRelative.keys)
        for key in allKeys.sorted() {
            switch (localByRelative[key], remoteByRelative[key]) {
            case let (local?, remote?):
                guard let data = try? Data(contentsOf: local) else {
                    // Unreadable locally — treat as a diff so the user sees it.
                    diffs.append(BundleConflict.DifferingPath(relativePath: key, kind: .contentDiffers))
                    continue
                }
                let localSHA = gitBlobSHA(forData: data)
                if localSHA != remote.sha {
                    diffs.append(BundleConflict.DifferingPath(relativePath: key, kind: .contentDiffers))
                }
            case (.some, .none):
                diffs.append(BundleConflict.DifferingPath(relativePath: key, kind: .localOnly))
            case (.none, .some):
                diffs.append(BundleConflict.DifferingPath(relativePath: key, kind: .remoteOnly))
            case (.none, .none):
                break // unreachable by construction
            }
        }
        return diffs
    }

    /// Resolve a bundle-level conflict. `keepLocal` re-pushes every file in
    /// the local bundle (overwriting the remote) and deletes remote-only
    /// paths so the trees line up. `keepRemote` deletes the local bundle
    /// directory, then re-downloads the remote tree.
    func resolveBundleConflict(
        _ conflict: BundleConflict,
        resolution: ConflictResolution,
        owner: String,
        repo: String,
        token: String,
        presetManager: PresetManager
    ) async {
        let remotePrefix = "\(Self.remoteBundlesPrefix)/\(conflict.bundleName)"

        switch resolution {
        case .keepLocal:
            // Push every local file. Then for each remote-only path, fetch
            // its SHA from the conflict and delete it so the remote tree
            // matches local.
            backgroundPushBundle(
                bundleName: conflict.bundleName,
                bundleURL: conflict.localBundleURL,
                owner: owner, repo: repo, token: token
            )
            let toDelete = conflict.differingPaths.filter { $0.kind == .remoteOnly }
            let remoteByRelative = Dictionary(uniqueKeysWithValues:
                conflict.remoteFiles
                    .filter { $0.path.hasPrefix("\(remotePrefix)/") }
                    .map { (String($0.path.dropFirst(remotePrefix.count + 1)), $0.sha) }
            )
            for diff in toDelete {
                guard let sha = remoteByRelative[diff.relativePath] else { continue }
                do {
                    try await client.deleteFile(
                        owner: owner, repo: repo,
                        path: "\(remotePrefix)/\(diff.relativePath)",
                        sha: sha,
                        message: "Remove \(conflict.bundleName)/\(diff.relativePath) (keep-local resolve)",
                        token: token
                    )
                    remoteSHAs.removeValue(forKey: "\(remotePrefix)/\(diff.relativePath)")
                } catch {
                    log.error("Bundle conflict cleanup failed for \(diff.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

        case .keepRemote:
            // Blow away the local bundle directory so the pull writes a
            // clean tree. Any files the user added locally are lost — that
            // was the contract they picked.
            try? FileManager.default.removeItem(at: conflict.localBundleURL)
            do {
                try FileManager.default.createDirectory(
                    at: conflict.localBundleURL, withIntermediateDirectories: true
                )
                for file in conflict.remoteFiles where file.path.hasPrefix("\(remotePrefix)/") {
                    let relative = String(file.path.dropFirst(remotePrefix.count + 1))
                    let data = try await client.fetchFileData(
                        owner: owner, repo: repo, path: file.path, token: token
                    )
                    let destURL = conflict.localBundleURL.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(
                        at: destURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: destURL, options: .atomic)
                    remoteSHAs[file.path] = file.sha
                }
            } catch {
                log.error("Bundle conflict keep-remote failed for \(conflict.bundleName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        pendingBundleConflicts.removeAll { $0.id == conflict.id }
        presetManager.refreshPresets()
    }

    /// Clear all cached sync state (called on disconnect).
    func reset() {
        remoteSHAs = [:]
        pendingConflicts = []
        pendingBundleConflicts = []
        hasPendingChanges = false
        error = nil
    }

    // MARK: - Bundle sync (Phase A′)

    /// Remote prefix under which bundles live. The per-language `python/` and
    /// `rust/` directories continue to hold legacy single-file presets — they
    /// never contain directories, and sync logic for them is unchanged.
    private static let remoteBundlesPrefix = "bundles"

    /// Enumerate every file inside a local bundle directory, yielding each
    /// file's on-disk URL plus its relative path inside the bundle
    /// (e.g. "manifest.json", "process.py", "ui/index.html"). Hidden files
    /// and macOS metadata junk (`.DS_Store`, `._*`) are filtered out.
    nonisolated private static func enumerateBundleFiles(at bundleURL: URL) -> [(URL, String)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [(URL, String)] = []
        for case let url as URL in enumerator {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegular else { continue }
            if url.lastPathComponent.hasPrefix("._") || url.lastPathComponent == ".DS_Store" { continue }
            // Relative path inside the bundle — what GitHub will see as the
            // sub-path after `bundles/<name>/`.
            let relative = String(url.path.dropFirst(bundleURL.path.count + 1))
            results.append((url, relative))
        }
        return results
    }

    /// Push every file in a local bundle up to `bundles/<name>/` on the
    /// remote. Uses cached SHAs where present (so repeated saves of the same
    /// unchanged file skip the network round-trip); computes git blob SHAs
    /// locally and compares against the cache before writing.
    func backgroundPushBundle(
        bundleName: String,
        bundleURL: URL,
        owner: String,
        repo: String,
        token: String
    ) {
        let remoteBundlePrefix = "\(Self.remoteBundlesPrefix)/\(bundleName)"
        let files = Self.enumerateBundleFiles(at: bundleURL)

        Task.detached { [client, log] in
            var pushed = 0
            var skipped = 0
            for (fileURL, relative) in files {
                let remotePath = "\(remoteBundlePrefix)/\(relative)"
                guard let data = try? Data(contentsOf: fileURL) else {
                    log.warning("Bundle file unreadable, skipping: \(relative, privacy: .public)")
                    continue
                }
                // Local git-blob SHA for change detection. Works identically
                // for text and binary since it SHA1's the raw bytes.
                let localSHA = Self.gitBlobSHA(forData: data)
                let remoteSHA = await MainActor.run { self.remoteSHAs[remotePath] }
                if let remoteSHA, remoteSHA == localSHA {
                    skipped += 1
                    continue
                }
                do {
                    // Data-based putFile so binary assets (PNG, WOFF, …) in
                    // ui/assets survive the round-trip. Text files use the
                    // same path — the client base64-encodes in both cases.
                    let response = try await client.putFileData(
                        owner: owner, repo: repo, path: remotePath,
                        data: data,
                        message: "Update \(bundleName)/\(relative)",
                        sha: remoteSHA, token: token
                    )
                    await MainActor.run { self.remoteSHAs[remotePath] = response.content.sha }
                    pushed += 1
                } catch {
                    log.error("Bundle push \(remotePath, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    await MainActor.run { self.hasPendingChanges = true }
                }
            }
            log.info("Bundle push: \(bundleName, privacy: .public) pushed=\(pushed), skipped=\(skipped)")
            await MainActor.run { self.hasPendingChanges = false }
        }
    }

    /// Delete every remote file under `bundles/<name>/`. Uses the Tree API
    /// to enumerate files in a single call (so large bundles don't hit the
    /// contents API N times just to discover SHAs).
    func backgroundDeleteBundle(
        bundleName: String,
        owner: String,
        repo: String,
        token: String
    ) {
        let remoteBundlePrefix = "\(Self.remoteBundlesPrefix)/\(bundleName)"

        Task.detached { [client, log] in
            // Enumerate current remote state via Tree API. If the endpoint
            // returns nothing (bundle never made it remotely), drop the
            // cached entries locally and return quietly.
            let remoteFiles = (try? await client.listTreeFiles(
                owner: owner, repo: repo, pathPrefix: remoteBundlePrefix, token: token
            )) ?? []

            for file in remoteFiles {
                let sha = file.sha
                do {
                    try await client.deleteFile(
                        owner: owner, repo: repo, path: file.path,
                        sha: sha, message: "Delete \(file.path)", token: token
                    )
                    await MainActor.run { self.remoteSHAs.removeValue(forKey: file.path) }
                } catch {
                    log.error("Bundle delete \(file.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            // Belt-and-suspenders: also clear any locally-cached SHAs under
            // the prefix (covers files that existed locally but never made
            // it to the remote).
            await MainActor.run {
                for key in self.remoteSHAs.keys where key.hasPrefix("\(remoteBundlePrefix)/") {
                    self.remoteSHAs.removeValue(forKey: key)
                }
            }
            log.info("Bundle delete: \(bundleName, privacy: .public) removed \(remoteFiles.count) files")
        }
    }

    /// Rename a bundle on the remote: push the new name's contents first,
    /// then delete the old prefix. Same safety property as the single-file
    /// rename — if the push fails, the old directory remains intact.
    func backgroundRenameBundle(
        oldName: String,
        newName: String,
        newBundleURL: URL,
        owner: String,
        repo: String,
        token: String
    ) {
        // Push first; the push helper is idempotent and safe to run
        // unconditionally.
        backgroundPushBundle(
            bundleName: newName, bundleURL: newBundleURL,
            owner: owner, repo: repo, token: token
        )
        // Then cascade-delete the old prefix. This schedules a second task
        // that races with the push above, which is fine — they operate on
        // disjoint remote paths.
        backgroundDeleteBundle(
            bundleName: oldName,
            owner: owner, repo: repo, token: token
        )
    }

    /// Pull any bundles that exist under `bundles/` remotely but not in
    /// `repoPresetsURL` locally. Conflict detection for bundles is scoped
    /// out for the first pass — if both sides have a `bundles/<name>/`, the
    /// local one wins and a follow-up sync re-pushes.
    func pullBundlesOnConnect(
        owner: String,
        repo: String,
        token: String,
        presetManager: PresetManager
    ) async {
        // One Tree API call gets every file under `bundles/`.
        let files: [GitHubTreeFile]
        do {
            files = try await client.listTreeFiles(
                owner: owner, repo: repo,
                pathPrefix: Self.remoteBundlesPrefix, token: token
            )
        } catch {
            log.warning("Tree fetch for bundles/ failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if files.isEmpty { return }

        // Group files by their immediate `bundles/<name>/` bucket.
        var filesByBundle: [String: [GitHubTreeFile]] = [:]
        for file in files {
            let parts = file.path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 3, parts[0] == Self.remoteBundlesPrefix else { continue }
            filesByBundle[String(parts[1]), default: []].append(file)
        }

        let fm = FileManager.default
        for (bundleName, bundleFiles) in filesByBundle {
            let localBundleURL = presetManager.repoPresetsURL.appendingPathComponent(
                "\(bundleName).\(PresetBundle.bundleExtension)", isDirectory: true
            )
            if fm.fileExists(atPath: localBundleURL.path) {
                // Both sides have the bundle. Compare by SHA — if every
                // file agrees, seed remoteSHAs and move on; otherwise
                // surface a conflict for the user to resolve.
                let diffs = Self.diffBundle(
                    localBundleURL: localBundleURL,
                    bundleName: bundleName,
                    remoteFiles: bundleFiles
                )
                // Always seed SHAs so a later keep-local push skips
                // unchanged blobs.
                for file in bundleFiles {
                    remoteSHAs[file.path] = file.sha
                }
                if !diffs.isEmpty {
                    pendingBundleConflicts.append(BundleConflict(
                        bundleName: bundleName,
                        localBundleURL: localBundleURL,
                        differingPaths: diffs,
                        remoteFiles: bundleFiles
                    ))
                    log.info("Bundle conflict detected: \(bundleName, privacy: .public) (\(diffs.count) paths differ)")
                }
                continue
            }
            do {
                try fm.createDirectory(at: localBundleURL, withIntermediateDirectories: true)
                for file in bundleFiles {
                    let relative = String(file.path.dropFirst(
                        "\(Self.remoteBundlesPrefix)/\(bundleName)/".count
                    ))
                    // Data-based fetch handles both text and binary payloads.
                    // Previous string-based fetch would throw on PNG/WOFF
                    // assets because the UTF-8 decode in fetchFileContent
                    // rejects non-text bytes.
                    let data = try await client.fetchFileData(
                        owner: owner, repo: repo, path: file.path, token: token
                    )
                    let destURL = localBundleURL.appendingPathComponent(relative)
                    try fm.createDirectory(
                        at: destURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: destURL, options: .atomic)
                    remoteSHAs[file.path] = file.sha
                }
                log.info("Pulled bundle: \(bundleName, privacy: .public) with \(bundleFiles.count) files")
            } catch {
                log.error("Bundle pull \(bundleName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    /// Compute the git blob SHA1 for a string: SHA1("blob <size>\0<content>").
    /// This matches the SHA that GitHub reports for file contents.
    nonisolated static func gitBlobSHA(for content: String) -> String {
        gitBlobSHA(forData: Data(content.utf8))
    }

    /// Compute the git blob SHA1 for raw bytes. Same format as the string
    /// variant — git SHAs the raw content prefixed with `blob <byte-count>\0`
    /// regardless of whether the content is text or binary, so this handles
    /// images/fonts in `ui/assets/` identically.
    nonisolated static func gitBlobSHA(forData data: Data) -> String {
        let header = "blob \(data.count)\0"
        var blob = Data(header.utf8)
        blob.append(data)
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
