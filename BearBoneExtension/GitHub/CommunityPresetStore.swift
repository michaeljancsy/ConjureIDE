import Combine
import Foundation
import os

/// Fetches, caches, and provides the community preset catalog from a public GitHub repo.
@MainActor
class CommunityPresetStore: ObservableObject {
    @Published private(set) var catalog: [CommunityPresetEntry] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private let client: GitHubClient
    private let owner: String
    private let repo: String
    private let branch: String
    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "CommunityPresets")

    /// How long a cached manifest stays valid.
    private let cacheTTL: TimeInterval = 3600 // 1 hour

    private var cacheDirectory: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("BearBone", isDirectory: true)
            .appendingPathComponent("community-cache", isDirectory: true)
    }

    private var cachedManifestURL: URL {
        cacheDirectory.appendingPathComponent("index.json")
    }

    init(
        client: GitHubClient = GitHubClient(),
        owner: String = "michaeljancsy",
        repo: String = "bearbone-presets",
        branch: String = "main"
    ) {
        self.client = client
        self.owner = owner
        self.repo = repo
        self.branch = branch
    }

    // MARK: - Fetch Catalog

    /// Load the community preset catalog. Shows cached data immediately, refreshes in background.
    func loadCatalog() async {
        // Load from cache first
        if catalog.isEmpty, let cached = loadCachedManifest() {
            catalog = cached.presets
        }

        // Fetch fresh from GitHub
        isLoading = true
        error = nil

        do {
            let json = try await client.fetchRawFile(
                owner: owner, repo: repo, branch: branch, path: "index.json"
            )
            let manifest = try decodeManifest(json)
            catalog = manifest.presets
            saveCachedManifest(json)
            log.info("Loaded \(manifest.presets.count) community presets")
        } catch {
            log.error("Failed to fetch community catalog: \(error.localizedDescription, privacy: .public)")
            // Only show error if we have nothing cached
            if catalog.isEmpty {
                self.error = error.localizedDescription
            }
        }

        isLoading = false
    }

    // MARK: - Fetch Preset Source

    /// Download the source code for a community preset.
    func fetchPresetSource(for entry: CommunityPresetEntry) async throws -> String {
        try await client.fetchRawFile(
            owner: owner, repo: repo, branch: branch, path: entry.filename
        )
    }

    // MARK: - Install

    /// Download and install a community preset into the user's local presets.
    func installPreset(_ entry: CommunityPresetEntry, into presetManager: PresetManager) async throws -> Preset {
        let source = try await fetchPresetSource(for: entry)
        let name = presetManager.uniqueName(baseName: entry.name)
        return try presetManager.saveUserPreset(
            name: name,
            source: source,
            language: entry.scriptLanguage
        )
    }

    // MARK: - Cache

    private func loadCachedManifest() -> CommunityManifest? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cachedManifestURL.path) else { return nil }

        // Check TTL
        if let attrs = try? fm.attributesOfItem(atPath: cachedManifestURL.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > cacheTTL
        {
            return nil
        }

        guard let data = try? Data(contentsOf: cachedManifestURL),
              let json = String(data: data, encoding: .utf8)
        else { return nil }

        return try? decodeManifest(json)
    }

    private func saveCachedManifest(_ json: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try json.write(to: cachedManifestURL, atomically: true, encoding: .utf8)
        } catch {
            log.warning("Failed to cache community manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func decodeManifest(_ json: String) throws -> CommunityManifest {
        guard let data = json.data(using: .utf8) else {
            throw GitHubError.decodingError("Invalid UTF-8 in manifest")
        }
        do {
            return try JSONDecoder().decode(CommunityManifest.self, from: data)
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }
    }
}
