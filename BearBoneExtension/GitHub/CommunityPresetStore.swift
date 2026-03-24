import Combine
import Foundation
import os

/// Fetches, caches, and provides community presets from a public GitHub repo.
/// Discovers presets by listing python/ and rust/ subdirectories and reading
/// sidecar _metadata.json files for each script.
@MainActor
class CommunityPresetStore: ObservableObject {
    @Published private(set) var catalog: [RepoPresetEntry] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    private let client: GitHubClient
    private let owner: String
    private let repo: String
    private let branch: String
    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "CommunityPresets")

    /// How long a cached catalog stays valid.
    private let cacheTTL: TimeInterval = 3600 // 1 hour

    private var cacheDirectory: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("BearBone", isDirectory: true)
            .appendingPathComponent("community-cache", isDirectory: true)
    }

    private var cachedCatalogURL: URL {
        cacheDirectory.appendingPathComponent("catalog.json")
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
        if catalog.isEmpty, let cached = loadCachedCatalog() {
            catalog = cached
        }

        // Fetch fresh from GitHub
        isLoading = true
        error = nil

        do {
            let entries = try await discoverPresets()
            catalog = entries
            saveCachedCatalog(entries)
            log.info("Loaded \(entries.count) community presets")
        } catch {
            log.error("Failed to fetch community catalog: \(error.localizedDescription, privacy: .public)")
            if catalog.isEmpty {
                self.error = error.localizedDescription
            }
        }

        isLoading = false
    }

    // MARK: - Discovery

    /// Discover all presets by listing python/ and rust/ directories and fetching metadata.
    private func discoverPresets() async throws -> [RepoPresetEntry] {
        var entries: [RepoPresetEntry] = []

        for (subdir, ext, language) in [("python", "py", ScriptLanguage.python), ("rust", "rs", ScriptLanguage.rust)] {
            let files: [GitHubContentsResponse]
            do {
                files = try await client.listContents(owner: owner, repo: repo, path: subdir, token: "")
            } catch {
                continue // Subdirectory may not exist
            }

            let scriptFiles = files.filter { $0.type == "file" && $0.name.hasSuffix(".\(ext)") }

            for file in scriptFiles {
                let stem = (file.name as NSString).deletingPathExtension
                let metadataFilename = PresetMetadata.metadataFilename(forScript: file.name)
                let metadataPath = "\(subdir)/\(metadataFilename)"

                // Try to fetch sidecar metadata
                var metadata: PresetMetadata
                do {
                    let json = try await client.fetchRawFile(owner: owner, repo: repo, branch: branch, path: metadataPath)
                    if let data = json.data(using: .utf8) {
                        metadata = try JSONDecoder().decode(PresetMetadata.self, from: data)
                    } else {
                        metadata = PresetMetadata(name: stem)
                    }
                } catch {
                    // No metadata file — use filename as name
                    metadata = PresetMetadata(name: stem)
                }

                entries.append(RepoPresetEntry(
                    scriptFilename: file.name,
                    remotePath: "\(subdir)/\(file.name)",
                    language: language,
                    metadata: metadata
                ))
            }
        }

        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Fetch Preset Source

    /// Download the source code for a community preset.
    func fetchPresetSource(for entry: RepoPresetEntry) async throws -> String {
        try await client.fetchRawFile(owner: owner, repo: repo, branch: branch, path: entry.remotePath)
    }

    // MARK: - Install

    /// Download and install a community preset into the user's local presets.
    func installPreset(_ entry: RepoPresetEntry, into presetManager: PresetManager) async throws -> Preset {
        let source = try await fetchPresetSource(for: entry)
        let name = presetManager.uniqueName(baseName: entry.name)
        return try presetManager.saveUserPreset(
            name: name,
            source: source,
            language: entry.language
        )
    }

    // MARK: - Cache

    /// Cached catalog entry for JSON serialization.
    private struct CachedEntry: Codable {
        let scriptFilename: String
        let remotePath: String
        let language: String
        let name: String
        let category: String?
        let author: String?
        let description: String?
    }

    private func loadCachedCatalog() -> [RepoPresetEntry]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: cachedCatalogURL.path) else { return nil }

        if let attrs = try? fm.attributesOfItem(atPath: cachedCatalogURL.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > cacheTTL
        {
            return nil
        }

        guard let data = try? Data(contentsOf: cachedCatalogURL),
              let cached = try? JSONDecoder().decode([CachedEntry].self, from: data)
        else { return nil }

        return cached.map { entry in
            RepoPresetEntry(
                scriptFilename: entry.scriptFilename,
                remotePath: entry.remotePath,
                language: entry.language == "rust" ? .rust : .python,
                metadata: PresetMetadata(
                    name: entry.name,
                    category: entry.category,
                    author: entry.author,
                    description: entry.description
                )
            )
        }
    }

    private func saveCachedCatalog(_ entries: [RepoPresetEntry]) {
        let fm = FileManager.default
        let cached = entries.map { entry in
            CachedEntry(
                scriptFilename: entry.scriptFilename,
                remotePath: entry.remotePath,
                language: entry.language == .rust ? "rust" : "python",
                name: entry.name,
                category: entry.metadata.category,
                author: entry.metadata.author,
                description: entry.metadata.description
            )
        }
        do {
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cached)
            try data.write(to: cachedCatalogURL, options: .atomic)
        } catch {
            log.warning("Failed to cache community catalog: \(error.localizedDescription, privacy: .public)")
        }
    }
}
