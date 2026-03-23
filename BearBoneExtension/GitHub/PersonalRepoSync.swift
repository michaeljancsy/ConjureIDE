import Combine
import Foundation
import os

/// Explicit push/pull sync of user presets with a personal GitHub repo.
@MainActor
class PersonalRepoSync: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published var error: String?
    @Published var lastSyncDate: Date? {
        didSet {
            if let date = lastSyncDate {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "github.lastSyncTimestamp")
            }
        }
    }

    private let client: GitHubClient
    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "PersonalRepoSync")

    init(client: GitHubClient) {
        self.client = client
        let ts = UserDefaults.standard.double(forKey: "github.lastSyncTimestamp")
        if ts > 0 {
            self.lastSyncDate = Date(timeIntervalSince1970: ts)
        }
    }

    // MARK: - Pull

    struct PullResult {
        var installed: [String] = []
        var updated: [String] = []
        var skipped: [String] = []
    }

    /// Pull presets from the personal repo. New presets are installed; existing ones
    /// with the same name are skipped (user can choose to overwrite via conflicts).
    func pull(
        owner: String,
        repo: String,
        token: String,
        presetManager: PresetManager
    ) async throws -> PullResult {
        isSyncing = true
        error = nil
        defer { isSyncing = false }

        let remoteFiles: [GitHubContentsResponse]
        do {
            remoteFiles = try await client.listContents(owner: owner, repo: repo, token: token)
        } catch {
            self.error = error.localizedDescription
            throw error
        }

        let presetFiles = remoteFiles.filter { file in
            file.type == "file" && (file.name.hasSuffix(".py") || file.name.hasSuffix(".rs"))
        }

        var result = PullResult()

        for file in presetFiles {
            let ext = (file.name as NSString).pathExtension
            let name = (file.name as NSString).deletingPathExtension
            let language: ScriptLanguage = ext == "rs" ? .rust : .python

            if presetManager.userPresetExists(name: name) {
                result.skipped.append(name)
                continue
            }

            do {
                let source = try await client.fetchRawFile(owner: owner, repo: repo, path: file.name)
                let uniqueName = presetManager.uniqueName(baseName: name)
                try presetManager.saveUserPreset(name: uniqueName, source: source, language: language)
                result.installed.append(uniqueName)
                log.info("Pulled preset: \(uniqueName, privacy: .public)")
            } catch {
                log.error("Failed to pull \(file.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                result.skipped.append(name)
            }
        }

        lastSyncDate = Date()
        return result
    }

    // MARK: - Push

    struct PushResult {
        var created: Int = 0
        var updated: Int = 0
        var unchanged: Int = 0
    }

    /// Push all user presets to the personal repo. Uses SHA-based change detection
    /// to avoid unnecessary writes.
    func push(
        owner: String,
        repo: String,
        token: String,
        presetManager: PresetManager
    ) async throws -> PushResult {
        isSyncing = true
        error = nil
        defer { isSyncing = false }

        // Get existing remote files to detect changes via SHA
        let remoteFiles: [GitHubContentsResponse]
        do {
            remoteFiles = try await client.listContents(owner: owner, repo: repo, token: token)
        } catch let e as GitHubError where e.localizedDescription.contains("Not found") {
            // Repo might be empty — that's fine, we'll create all files
            remoteFiles = []
        } catch {
            self.error = error.localizedDescription
            throw error
        }

        let remoteBySHA = Dictionary(uniqueKeysWithValues: remoteFiles.compactMap { file -> (String, String)? in
            guard file.type == "file" else { return nil }
            return (file.name, file.sha)
        })

        let userPresets = presetManager.presets.filter { !$0.isFactory }
        var result = PushResult()

        for preset in userPresets {
            guard let source = presetManager.loadSource(for: preset) else { continue }
            let filename = "\(preset.name).\(preset.fileExtension)"

            let existingSHA = remoteBySHA[filename]

            do {
                _ = try await client.putFile(
                    owner: owner,
                    repo: repo,
                    path: filename,
                    content: source,
                    message: "Update \(preset.name)",
                    sha: existingSHA,
                    token: token
                )
                if existingSHA != nil {
                    result.updated += 1
                } else {
                    result.created += 1
                }
                log.info("Pushed preset: \(filename, privacy: .public)")
            } catch {
                log.error("Failed to push \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        lastSyncDate = Date()
        return result
    }

    // MARK: - Force Pull (overwrite local)

    /// Pull a specific preset from the repo, overwriting the local version.
    func forcePull(
        name: String,
        owner: String,
        repo: String,
        token: String,
        presetManager: PresetManager
    ) async throws -> Preset {
        let ext = name.hasSuffix(".rs") ? "rs" : "py"
        let filename = name.hasSuffix(".py") || name.hasSuffix(".rs") ? name : "\(name).\(ext)"
        let source = try await client.fetchRawFile(owner: owner, repo: repo, path: filename)
        let presetName = (filename as NSString).deletingPathExtension
        let language: ScriptLanguage = ext == "rs" ? .rust : .python
        return try presetManager.saveUserPreset(name: presetName, source: source, language: language)
    }
}
