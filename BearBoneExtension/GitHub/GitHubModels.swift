import Foundation

// MARK: - Repo Marker

/// Marker file at the root of a BearBone preset repo.
/// Presence of `bearbone.json` identifies a repo as a BearBone preset repo.
struct BearBoneRepoMarker: Codable {
    let version: Int
    let type: String  // "presets"

    static let filename = "bearbone.json"

    static func create() -> BearBoneRepoMarker {
        BearBoneRepoMarker(version: 1, type: "presets")
    }
}

// MARK: - Community Manifest

struct CommunityManifest: Codable {
    let version: Int
    let presets: [CommunityPresetEntry]
}

struct CommunityPresetEntry: Codable, Identifiable {
    let name: String
    let filename: String
    let language: String
    let category: String
    let author: String
    let description: String

    var id: String { filename }

    var scriptLanguage: ScriptLanguage {
        language == "rust" ? .rust : .python
    }
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
