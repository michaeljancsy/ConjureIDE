import Foundation

// MARK: - Repo Marker

/// Marker file at the root of a ConjureDSP preset repo.
/// Presence of `conjuredsp.json` identifies a repo as a ConjureDSP preset repo.
struct ConjureDSPRepoMarker: Codable {
    let version: Int
    let type: String  // "presets"

    static let filename = "conjuredsp.json"

    static func create() -> ConjureDSPRepoMarker {
        ConjureDSPRepoMarker(version: 1, type: "presets")
    }
}

// MARK: - Preset Metadata

/// Sidecar metadata file stored next to each preset script.
/// e.g. `python/slicer_metadata.json` accompanies `python/slicer.py`.
/// Used by personal repo sync.
struct PresetMetadata: Codable, Identifiable {
    let name: String
    var category: String?
    var author: String?
    var description: String?

    var id: String { name }

    /// Filename for the metadata sidecar: `<script_stem>_metadata.json`
    static func metadataFilename(forScript scriptFilename: String) -> String {
        let stem = (scriptFilename as NSString).deletingPathExtension
        return "\(stem)_metadata.json"
    }

    /// Encode to pretty-printed JSON Data.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// A discovered preset from a repo: the script file info + its metadata.
struct RepoPresetEntry: Identifiable {
    let scriptFilename: String
    let remotePath: String
    let language: ScriptLanguage
    let metadata: PresetMetadata

    var id: String { remotePath }
    var name: String { metadata.name }
}

// MARK: - GitHub API Responses

struct GitHubContentsResponse: Codable {
    let name: String
    let path: String
    let sha: String
    let size: Int
    let content: String?
    let downloadURL: String?
    let type: String

    enum CodingKeys: String, CodingKey {
        case name, path, sha, size, content, type
        case downloadURL = "download_url"
    }
}

struct GitHubCommitResponse: Codable {
    let content: GitHubContentsResponse
    let commit: CommitInfo

    struct CommitInfo: Codable {
        let sha: String
        let message: String
    }
}

struct CreateRepoResponse: Codable {
    let name: String
    let fullName: String
    let htmlURL: String
    let cloneURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case htmlURL = "html_url"
        case cloneURL = "clone_url"
    }
}

// MARK: - Errors

enum GitHubError: LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case rateLimited(retryAfterSeconds: Int?)
    case notFound
    case decodingError(String)
    case permissionDenied(message: String)
    case networkError(Error)
    case noToken

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .httpError(let code, let message):
            return "HTTP \(code): \(message)"
        case .rateLimited(let seconds):
            if let s = seconds {
                return "Rate limited — retry after \(s)s"
            }
            return "Rate limited — try again later"
        case .permissionDenied:
            return "Permission denied — check your token has the required scopes"
        case .notFound:
            return "Not found"
        case .decodingError(let detail):
            return "Failed to decode response: \(detail)"
        case .networkError(let error):
            return error.localizedDescription
        case .noToken:
            return "GitHub token required"
        }
    }
}
