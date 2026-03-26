import Foundation
import os

// MARK: - ETag Cache

/// Thread-safe in-memory cache for HTTP ETag conditional requests.
/// Stores ETags and response data keyed by URL, enabling 304 Not Modified responses.
private actor ETagCache {
    struct Entry {
        let etag: String
        let data: Data
        let response: HTTPURLResponse
    }

    private var entries: [URL: Entry] = [:]

    func get(_ url: URL) -> Entry? { entries[url] }
    func set(_ url: URL, _ entry: Entry) { entries[url] = entry }
}

/// Low-level wrapper around the GitHub REST API and generic URL fetching.
final class GitHubClient: Sendable {
    private let session: URLSession
    private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "GitHub")
    private let etagCache = ETagCache()

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Generic URL Fetch

    /// Fetch raw text from any HTTPS URL. Automatically converts GitHub blob/Gist
    /// URLs to their raw equivalents so users can paste any GitHub link.
    func fetchURL(_ url: URL) async throws -> String {
        let (text, _) = try await fetchURLWithResponseURL(url)
        return text
    }

    /// Fetch raw text and return the final response URL (after redirects).
    /// Useful for gist URLs where GitHub redirects to a URL containing the actual filename.
    func fetchURLWithResponseURL(_ url: URL) async throws -> (String, URL) {
        let resolved = GitHubClient.normalizeToRawURL(url)
        var request = URLRequest(url: resolved)
        request.setValue("ConjureDSP-AUv3", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await perform(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitHubError.decodingError("Response is not valid UTF-8")
        }
        return (text, response.url ?? resolved)
    }

    /// Convert GitHub web URLs to raw content URLs.
    ///
    /// Handles:
    /// - `github.com/{owner}/{repo}/blob/{branch}/{path}` → `raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}`
    /// - `github.com/{owner}/{repo}/raw/{branch}/{path}` → `raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}`
    /// - `gist.github.com/{owner}/{id}` → `gist.githubusercontent.com/{owner}/{id}/raw`
    /// - `gist.github.com/{owner}/{id}#file-{name}` → extracts from Gist API
    /// - Already-raw URLs are returned unchanged.
    static func normalizeToRawURL(_ url: URL) -> URL {
        let host = url.host?.lowercased() ?? ""
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        // github.com/{owner}/{repo}/blob/{branch}/{path...}
        // github.com/{owner}/{repo}/raw/{branch}/{path...}
        if host == "github.com" || host == "www.github.com",
           pathComponents.count >= 4,
           pathComponents[2] == "blob" || pathComponents[2] == "raw"
        {
            let owner = pathComponents[0]
            let repo = pathComponents[1]
            let branch = pathComponents[3]
            let filePath = pathComponents.dropFirst(4).joined(separator: "/")
            let encodedFilePath = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
            if let rawURL = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(encodedFilePath)") {
                return rawURL
            }
        }

        // gist.github.com/{owner}/{id} → gist.githubusercontent.com/{owner}/{id}/raw
        if host == "gist.github.com",
           pathComponents.count >= 2
        {
            let owner = pathComponents[0]
            let gistID = pathComponents[1]
            if let rawURL = URL(string: "https://gist.githubusercontent.com/\(owner)/\(gistID)/raw") {
                return rawURL
            }
        }

        return url
    }

    /// Returns a user-facing error if the URL is a known non-file pattern (e.g. GitHub repo root).
    static func validateImportURL(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if host == "github.com" || host == "www.github.com" {
            // Repo root: github.com/{owner}/{repo}
            if pathComponents.count <= 2 {
                return "This is a repo URL. Link to a specific .py or .rs file."
            }
            // Tree/folder view: github.com/{owner}/{repo}/tree/{branch}/...
            if pathComponents.count >= 3, pathComponents[2] == "tree" {
                return "This is a folder URL. Link to a specific .py or .rs file."
            }
        }
        return nil
    }

    // MARK: - Raw Content (raw.githubusercontent.com, not rate-limited like API)

    /// Fetch a raw file from a public GitHub repo via raw.githubusercontent.com.
    func fetchRawFile(owner: String, repo: String, branch: String = "main", path: String) async throws -> String {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(encodedPath)") else {
            throw GitHubError.invalidURL
        }
        return try await fetchURL(url)
    }

    // MARK: - Repo Info

    /// Check that a repo exists (and the token has access). Throws `notFound` if it doesn't.
    func checkRepoExists(owner: String, repo: String, token: String) async throws {
        let url = apiURL(path: "/repos/\(owner)/\(repo)")
        let request = apiRequest(url: url, method: "GET", token: token)
        _ = try await perform(request)
    }

    // MARK: - GitHub Contents API (authenticated)

    /// List the contents of a directory in a repo.
    func listContents(owner: String, repo: String, path: String = "", token: String) async throws -> [GitHubContentsResponse] {
        let url = apiURL(path: "/repos/\(owner)/\(repo)/contents/\(path)")
        let request = apiRequest(url: url, method: "GET", token: token)
        let (data, _) = try await perform(request)
        return try decode([GitHubContentsResponse].self, from: data)
    }

    /// Get a single file's metadata and content from a repo.
    func getFile(owner: String, repo: String, path: String, token: String) async throws -> GitHubContentsResponse {
        let url = apiURL(path: "/repos/\(owner)/\(repo)/contents/\(path)")
        let request = apiRequest(url: url, method: "GET", token: token)
        let (data, _) = try await perform(request)
        return try decode(GitHubContentsResponse.self, from: data)
    }

    /// Fetch a file's text content via the authenticated Contents API.
    /// Works for both public and private repos. Uses the `application/vnd.github.raw+json`
    /// accept header to get raw content directly (no base64 decoding needed).
    func fetchFileContent(owner: String, repo: String, path: String, token: String) async throws -> String {
        let url = apiURL(path: "/repos/\(owner)/\(repo)/contents/\(path)")
        var request = apiRequest(url: url, method: "GET", token: token)
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await perform(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitHubError.decodingError("Response is not valid UTF-8")
        }
        return text
    }

    /// Create or update a file in a repo. For updates, provide the file's current SHA.
    func putFile(
        owner: String,
        repo: String,
        path: String,
        content: String,
        message: String,
        sha: String? = nil,
        token: String
    ) async throws -> GitHubCommitResponse {
        let url = apiURL(path: "/repos/\(owner)/\(repo)/contents/\(path)")
        var body: [String: Any] = [
            "message": message,
            "content": Data(content.utf8).base64EncodedString(),
        ]
        if let sha {
            body["sha"] = sha
        }
        var request = apiRequest(url: url, method: "PUT", token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await perform(request)
        return try decode(GitHubCommitResponse.self, from: data)
    }

    // MARK: - Repo Management

    /// Create a new GitHub repository for the authenticated user.
    func createRepo(name: String, description: String, isPrivate: Bool, token: String) async throws -> CreateRepoResponse {
        let url = apiURL(path: "/user/repos")
        var request = apiRequest(url: url, method: "POST", token: token)
        let body: [String: Any] = [
            "name": name,
            "description": description,
            "private": isPrivate,
            "auto_init": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await perform(request)
        return try decode(CreateRepoResponse.self, from: data)
    }

    /// Delete a file from a repo. Requires the file's current SHA.
    func deleteFile(owner: String, repo: String, path: String, sha: String, message: String, token: String) async throws {
        let url = apiURL(path: "/repos/\(owner)/\(repo)/contents/\(path)")
        var request = apiRequest(url: url, method: "DELETE", token: token)
        let body: [String: Any] = [
            "message": message,
            "sha": sha,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    // MARK: - Helpers

    private func apiURL(path: String) -> URL {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://api.github.com\(encoded)")!
    }

    private func apiRequest(url: URL, method: String, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("ConjureDSP-AUv3", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if method == "PUT" || method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Perform an HTTP request with automatic retry (for idempotent methods) and ETag caching.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let maxAttempts = 7
        let method = request.httpMethod ?? "GET"
        let isIdempotent = ["GET", "PUT", "DELETE"].contains(method)

        var lastError: Error?
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                let delay = retryDelay(attempt: attempt, lastError: lastError)
                log.warning("Retry \(attempt)/\(maxAttempts - 1) for \(request.url?.absoluteString ?? "?", privacy: .public) after \(String(format: "%.1f", delay))s")
                try await Task.sleep(for: .seconds(delay))
            }
            do {
                return try await performOnce(request)
            } catch {
                lastError = error
                if !isIdempotent || !Self.isRetryable(error) {
                    throw error
                }
            }
        }
        throw lastError!
    }

    /// Single-attempt HTTP request with ETag conditional request support.
    private func performOnce(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let isGET = (request.httpMethod ?? "GET") == "GET"

        // Add If-None-Match header for GET requests with cached ETags
        var cachedEntry: ETagCache.Entry?
        if isGET, let url = request.url {
            cachedEntry = await etagCache.get(url)
            if let etag = cachedEntry?.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubError.httpError(statusCode: 0, message: "Not an HTTP response")
        }

        // Handle 304 Not Modified — return cached data
        if httpResponse.statusCode == 304, let cached = cachedEntry {
            return (cached.data, cached.response)
        }

        switch httpResponse.statusCode {
        case 200...299:
            // Cache ETag for GET responses
            if isGET, let url = request.url,
               let etag = httpResponse.value(forHTTPHeaderField: "ETag") {
                await etagCache.set(url, ETagCache.Entry(etag: etag, data: data, response: httpResponse))
            }
            return (data, httpResponse)
        case 404:
            throw GitHubError.notFound
        case 403:
            // Distinguish rate limiting from permission errors
            let remaining = httpResponse.value(forHTTPHeaderField: "x-ratelimit-remaining")
            if remaining == "0" {
                let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after").flatMap(Int.init)
                throw GitHubError.rateLimited(retryAfterSeconds: retryAfter)
            }
            let message = String(data: data.prefix(500), encoding: .utf8) ?? "Forbidden"
            throw GitHubError.permissionDenied(message: message)
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after").flatMap(Int.init)
            throw GitHubError.rateLimited(retryAfterSeconds: retryAfter)
        default:
            let message = String(data: data.prefix(500), encoding: .utf8) ?? "Unknown error"
            throw GitHubError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    /// Whether an error is worth retrying (transient failures only).
    private static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case is GitHubError:
            switch error as! GitHubError {
            case .networkError:
                return true
            case .httpError(let code, _) where code >= 500:
                return true
            case .rateLimited:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    /// Compute retry delay with exponential backoff (1,2,4,8,16,32s) and ±20% jitter.
    /// For rate-limited responses, uses the server's retry-after value (capped at 32s).
    private func retryDelay(attempt: Int, lastError: Error?) -> Double {
        if let error = lastError as? GitHubError,
           case .rateLimited(let retryAfter) = error,
           let seconds = retryAfter {
            return min(Double(seconds), 32.0)
        }
        let base = pow(2.0, Double(attempt - 1)) // 1, 2, 4, 8, 16, 32
        let jitter = base * Double.random(in: -0.2...0.2)
        return min(base + jitter, 32.0)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }
    }
}
