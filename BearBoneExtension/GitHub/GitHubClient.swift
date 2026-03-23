import Foundation
import os

/// Low-level wrapper around the GitHub REST API and generic URL fetching.
final class GitHubClient: Sendable {
    private let session: URLSession
    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "GitHub")

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Generic URL Fetch

    /// Fetch raw text from any HTTPS URL. Automatically converts GitHub blob/Gist
    /// URLs to their raw equivalents so users can paste any GitHub link.
    func fetchURL(_ url: URL) async throws -> String {
        let resolved = GitHubClient.normalizeToRawURL(url)
        var request = URLRequest(url: resolved)
        request.setValue("BearBone-AUv3", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await perform(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitHubError.decodingError("Response is not valid UTF-8")
        }
        return text
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
            if let rawURL = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(filePath)") {
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

    // MARK: - Raw Content (raw.githubusercontent.com, not rate-limited like API)

    /// Fetch a raw file from a public GitHub repo via raw.githubusercontent.com.
    func fetchRawFile(owner: String, repo: String, branch: String = "main", path: String) async throws -> String {
        guard let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(path)") else {
            throw GitHubError.invalidURL
        }
        return try await fetchURL(url)
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
        URL(string: "https://api.github.com\(path)")!
    }

    private func apiRequest(url: URL, method: String, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("BearBone-AUv3", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if method == "PUT" || method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubError.httpError(statusCode: 0, message: "Not an HTTP response")
        }

        switch httpResponse.statusCode {
        case 200...299:
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

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubError.decodingError(error.localizedDescription)
        }
    }
}
