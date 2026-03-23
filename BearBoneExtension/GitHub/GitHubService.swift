import Combine
import Foundation
import os

/// Central coordinator for all GitHub features: PAT management, community browsing, personal sync.
@MainActor
final class GitHubService: ObservableObject {
    @Published var personalRepoOwner: String {
        didSet { UserDefaults.standard.set(personalRepoOwner, forKey: "github.personalRepo.owner") }
    }
    @Published var personalRepoName: String {
        didSet { UserDefaults.standard.set(personalRepoName, forKey: "github.personalRepo.name") }
    }

    let client: GitHubClient
    let communityStore: CommunityPresetStore
    let personalSync: PersonalRepoSync

    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "GitHubService")

    var hasPersonalRepo: Bool {
        !personalRepoOwner.isEmpty && !personalRepoName.isEmpty
    }

    var hasToken: Bool {
        token != nil
    }

    var token: String? {
        KeychainHelper.load(key: "gitHubToken")
    }

    init(client: GitHubClient = GitHubClient()) {
        self.client = client
        self.communityStore = CommunityPresetStore(client: client)
        self.personalSync = PersonalRepoSync(client: client)
        self.personalRepoOwner = UserDefaults.standard.string(forKey: "github.personalRepo.owner") ?? ""
        self.personalRepoName = UserDefaults.standard.string(forKey: "github.personalRepo.name") ?? ""
    }

    // MARK: - Token Management

    func setToken(_ token: String?) {
        if let token, !token.isEmpty {
            try? KeychainHelper.save(key: "gitHubToken", value: token)
        } else {
            KeychainHelper.delete(key: "gitHubToken")
        }
        objectWillChange.send()
    }

    // MARK: - Auto-Sync Wiring

    /// Hook into PresetManager to auto-sync repo preset saves/deletes.
    func wireAutoSync(presetManager: PresetManager) {
        presetManager.onRepoPresetSaved = { [weak self] name, source, language in
            self?.handleRepoPresetSaved(name: name, source: source, language: language)
        }
        presetManager.onRepoPresetDeleted = { [weak self] name, language in
            self?.handleRepoPresetDeleted(name: name, language: language)
        }
    }

    private func handleRepoPresetSaved(name: String, source: String, language: ScriptLanguage) {
        guard hasPersonalRepo, let token else { return }
        let ext = language == .rust ? "rs" : "py"
        let subdir = language == .rust ? "rust" : "python"
        let metadata = PresetMetadata(name: name)
        personalSync.backgroundPush(
            filename: "\(subdir)/\(name).\(ext)",
            source: source,
            metadata: metadata,
            owner: personalRepoOwner,
            repo: personalRepoName,
            token: token
        )
    }

    private func handleRepoPresetDeleted(name: String, language: ScriptLanguage) {
        guard hasPersonalRepo, let token else { return }
        let ext = language == .rust ? "rs" : "py"
        let subdir = language == .rust ? "rust" : "python"
        personalSync.backgroundDelete(
            filename: "\(subdir)/\(name).\(ext)",
            owner: personalRepoOwner,
            repo: personalRepoName,
            token: token
        )
    }

    // MARK: - Initial Sync

    /// Trigger a full sync with the personal repo. Called on connect and on launch.
    func syncIfConnected(presetManager: PresetManager) {
        guard hasPersonalRepo, let token else { return }
        Task {
            let result = await personalSync.syncOnConnect(
                owner: personalRepoOwner,
                repo: personalRepoName,
                token: token,
                presetManager: presetManager
            )
            log.info("Sync complete: pulled=\(result.pulled), pushed=\(result.pushed), conflicts=\(result.conflicts)")
        }
    }

    // MARK: - Repo Validation

    /// Validate that a repo is a BearBone preset repo by checking for bearbone.json.
    func validateRepo(owner: String, repo: String) async throws {
        guard let token else { throw GitHubError.noToken }
        let json: String
        do {
            json = try await client.fetchRawFile(owner: owner, repo: repo, path: BearBoneRepoMarker.filename)
        } catch {
            throw GitHubError.httpError(statusCode: 0, message: "Not a BearBone preset repo (missing bearbone.json)")
        }
        guard let data = json.data(using: .utf8),
              let marker = try? JSONDecoder().decode(BearBoneRepoMarker.self, from: data),
              marker.type == "presets" else {
            throw GitHubError.httpError(statusCode: 0, message: "Invalid bearbone.json — not a BearBone preset repo")
        }
    }

    // MARK: - Repo Creation

    /// Create a new GitHub repo for the user's presets, including bearbone.json marker
    /// and python/ and rust/ subdirectories.
    func createPresetRepo(
        name: String,
        isPrivate: Bool,
        presetManager: PresetManager
    ) async throws {
        guard let token else { throw GitHubError.noToken }

        let response = try await client.createRepo(
            name: name,
            description: "BearBone preset library",
            isPrivate: isPrivate,
            token: token
        )

        // Extract owner from full_name
        let parts = response.fullName.split(separator: "/")
        guard parts.count == 2 else { throw GitHubError.decodingError("Unexpected repo full_name") }

        let owner = String(parts[0])
        let repoName = String(parts[1])

        // Create bearbone.json marker
        let marker = BearBoneRepoMarker.create()
        let markerJSON = try JSONEncoder().encode(marker)
        let markerString = String(data: markerJSON, encoding: .utf8) ?? "{\"version\":1,\"type\":\"presets\"}"
        _ = try await client.putFile(
            owner: owner, repo: repoName, path: BearBoneRepoMarker.filename,
            content: markerString, message: "Initialize BearBone preset repo", token: token
        )

        // Create placeholder files to establish python/ and rust/ directories
        _ = try await client.putFile(
            owner: owner, repo: repoName, path: "python/.gitkeep",
            content: "", message: "Create python directory", token: token
        )
        _ = try await client.putFile(
            owner: owner, repo: repoName, path: "rust/.gitkeep",
            content: "", message: "Create rust directory", token: token
        )

        personalRepoOwner = owner
        personalRepoName = repoName

        log.info("Created repo: \(response.fullName, privacy: .public)")
    }

    // MARK: - Migration

    /// Upload all existing user presets to the connected repo.
    func migrateUserPresetsToRepo(presetManager: PresetManager) async throws -> Int {
        guard hasPersonalRepo, let token else { throw GitHubError.noToken }

        let userPresets = presetManager.presets.filter(\.isUser)
        var migrated = 0

        for preset in userPresets {
            guard let source = presetManager.loadSource(for: preset) else { continue }
            let subdir = preset.language == .rust ? "rust" : "python"
            let remotePath = "\(subdir)/\(preset.name).\(preset.fileExtension)"

            // Push script + metadata to GitHub
            do {
                _ = try await client.putFile(
                    owner: personalRepoOwner,
                    repo: personalRepoName,
                    path: remotePath,
                    content: source,
                    message: "Add \(preset.name)",
                    token: token
                )
                // Push sidecar metadata
                let metadata = PresetMetadata(name: preset.name)
                if let jsonData = try? metadata.jsonData(),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    let metadataFilename = PresetMetadata.metadataFilename(forScript: "\(preset.name).\(preset.fileExtension)")
                    _ = try await client.putFile(
                        owner: personalRepoOwner,
                        repo: personalRepoName,
                        path: "\(subdir)/\(metadataFilename)",
                        content: jsonString,
                        message: "Add metadata for \(preset.name)",
                        token: token
                    )
                }
            } catch {
                log.error("Failed to push \(remotePath, privacy: .public) during migration: \(error.localizedDescription, privacy: .public)")
                continue
            }

            // Move local file from Presets/ to RepoPresets/ (already pushed above, skip sync)
            do {
                try presetManager.migrateUserPresetToRepo(preset, triggerSync: false)
                migrated += 1
            } catch {
                log.error("Failed to migrate \(preset.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return migrated
    }

    // MARK: - Disconnect

    func disconnect() {
        personalRepoOwner = ""
        personalRepoName = ""
    }
}
