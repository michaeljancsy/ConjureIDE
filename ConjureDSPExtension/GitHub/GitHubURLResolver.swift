import Foundation

/// Standalone helper for the "Import from URL" flow.
///
/// Handles:
///   - `validateURL(_:)` — reject obvious non-file URLs (repo root, folder view)
///   - `normalizeToRawURL(_:)` — rewrite github.com/gist.github.com web URLs
///     to their raw equivalents so we can fetch the actual file contents
///   - `fetch(_:)` — perform the fetch and return the text + final URL
///
/// Extracted from the old GitHubClient so the rest of the REST-based preset
/// sync code could be deleted. No Keychain, no authentication — this works
/// against public URLs only.
struct GitHubURLResolver {
    enum ResolverError: LocalizedError {
        case invalidResponse
        case notUTF8
        case http(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid HTTP response"
            case .notUTF8: return "Response is not valid UTF-8"
            case .http(let code): return "HTTP \(code)"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Validation

    /// Returns a user-facing error string if the URL is a known non-file
    /// pattern (e.g. GitHub repo root or a tree/folder view).
    static func validateURL(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if host == "github.com" || host == "www.github.com" {
            if pathComponents.count <= 2 {
                return "This is a repo URL. Link to a specific .py or .rs file."
            }
            if pathComponents.count >= 3, pathComponents[2] == "tree" {
                return "This is a folder URL. Link to a specific .py or .rs file."
            }
        }
        return nil
    }

    // MARK: - URL normalization

    /// Convert GitHub web URLs to raw content URLs.
    ///
    /// - `github.com/{owner}/{repo}/blob/{branch}/{path}` → `raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}`
    /// - `github.com/{owner}/{repo}/raw/{branch}/{path}` → `raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}`
    /// - `gist.github.com/{owner}/{id}` → `gist.githubusercontent.com/{owner}/{id}/raw`
    /// - Already-raw URLs are returned unchanged.
    static func normalizeToRawURL(_ url: URL) -> URL {
        let host = url.host?.lowercased() ?? ""
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if (host == "github.com" || host == "www.github.com"),
           pathComponents.count >= 4,
           pathComponents[2] == "blob" || pathComponents[2] == "raw" {
            let owner = pathComponents[0]
            let repo = pathComponents[1]
            let branch = pathComponents[3]
            let filePath = pathComponents.dropFirst(4).joined(separator: "/")
            let encoded = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
            if let raw = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(encoded)") {
                return raw
            }
        }

        if host == "gist.github.com", pathComponents.count >= 2 {
            let owner = pathComponents[0]
            let gistID = pathComponents[1]
            if let raw = URL(string: "https://gist.githubusercontent.com/\(owner)/\(gistID)/raw") {
                return raw
            }
        }

        return url
    }

    // MARK: - Fetch

    /// Fetch text and return it along with the final response URL (after
    /// redirects — useful for gist URLs where GitHub picks a filename).
    func fetchWithResponseURL(_ url: URL) async throws -> (String, URL) {
        let resolved = Self.normalizeToRawURL(url)
        var request = URLRequest(url: resolved)
        request.setValue("ConjureDSP-AUv3", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ResolverError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ResolverError.http(statusCode: http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ResolverError.notUTF8
        }
        return (text, response.url ?? resolved)
    }
}
