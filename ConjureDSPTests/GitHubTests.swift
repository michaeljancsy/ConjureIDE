import CommonCrypto
import Foundation
import Testing

// =============================================================================
// Self-contained GitHub integration tests. No extension imports to avoid
// duplicate symbol issues when the AU extension is loaded in-process.
// Types and logic are copied from the extension target as needed.
// =============================================================================

// MARK: - Mock URLProtocol

/// Flexible mock that lets each test configure per-request responses.
final class MockGitHubProtocol: URLProtocol, @unchecked Sendable {
    /// Handler called for each request. Returns (data, statusCode, headers).
    nonisolated(unsafe) static var requestHandler: ((URLRequest) -> (Data, Int, [String: String]))?

    /// Log of all requests made, for asserting request count and headers.
    nonisolated(unsafe) static var requestLog: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestLog.append(request)
        let (data, statusCode, headers) = Self.requestHandler?(request)
            ?? (Data(), 200, [:])
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Reset state between tests.
    static func reset() {
        requestHandler = nil
        requestLog = []
    }
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockGitHubProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Copied GitHubError (from GitHubModels.swift)

private enum TestGitHubError: LocalizedError, Equatable {
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case rateLimited(retryAfterSeconds: Int?)
    case notFound
    case decodingError(String)
    case permissionDenied(message: String)
    case networkError(String) // simplified: stores description instead of Error
    case noToken

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .httpError(let code, let message): return "HTTP \(code): \(message)"
        case .rateLimited(let seconds):
            if let s = seconds { return "Rate limited — retry after \(s)s" }
            return "Rate limited — try again later"
        case .permissionDenied: return "Permission denied"
        case .notFound: return "Not found"
        case .decodingError(let detail): return "Failed to decode: \(detail)"
        case .networkError(let desc): return desc
        case .noToken: return "GitHub token required"
        }
    }
}

// MARK: - Copied ETag Cache (from GitHubClient.swift)

private actor TestETagCache {
    struct Entry {
        let etag: String
        let data: Data
        let response: HTTPURLResponse
    }

    private var entries: [URL: Entry] = [:]
    func get(_ url: URL) -> Entry? { entries[url] }
    func set(_ url: URL, _ entry: Entry) { entries[url] = entry }
}

// MARK: - Test Client (mirrors GitHubClient.perform logic)

/// Minimal replica of GitHubClient's perform/retry/ETag logic for isolated testing.
private final class TestGitHubClient: Sendable {
    let session: URLSession
    let etagCache = TestETagCache()
    let maxAttempts: Int
    /// Multiplier for retry delays (0.0 = instant retries for fast tests).
    let delayMultiplier: Double

    init(session: URLSession, maxAttempts: Int = 7, delayMultiplier: Double = 0.0) {
        self.session = session
        self.maxAttempts = maxAttempts
        self.delayMultiplier = delayMultiplier
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let isIdempotent = ["GET", "PUT", "DELETE"].contains(method)

        var lastError: (any Error)?
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                let delay = retryDelay(attempt: attempt, lastError: lastError) * delayMultiplier
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
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

    private func performOnce(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let isGET = (request.httpMethod ?? "GET") == "GET"

        var cachedEntry: TestETagCache.Entry?
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
            throw TestGitHubError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TestGitHubError.httpError(statusCode: 0, message: "Not an HTTP response")
        }

        if httpResponse.statusCode == 304, let cached = cachedEntry {
            return (cached.data, cached.response)
        }

        switch httpResponse.statusCode {
        case 200...299:
            if isGET, let url = request.url,
               let etag = httpResponse.value(forHTTPHeaderField: "ETag") {
                await etagCache.set(url, TestETagCache.Entry(etag: etag, data: data, response: httpResponse))
            }
            return (data, httpResponse)
        case 404:
            throw TestGitHubError.notFound
        case 403:
            let remaining = httpResponse.value(forHTTPHeaderField: "x-ratelimit-remaining")
            if remaining == "0" {
                let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after").flatMap(Int.init)
                throw TestGitHubError.rateLimited(retryAfterSeconds: retryAfter)
            }
            let message = String(data: data.prefix(500), encoding: .utf8) ?? "Forbidden"
            throw TestGitHubError.permissionDenied(message: message)
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after").flatMap(Int.init)
            throw TestGitHubError.rateLimited(retryAfterSeconds: retryAfter)
        default:
            let message = String(data: data.prefix(500), encoding: .utf8) ?? "Unknown error"
            throw TestGitHubError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        guard let err = error as? TestGitHubError else { return false }
        switch err {
        case .networkError:
            return true
        case .httpError(let code, _) where code >= 500:
            return true
        case .rateLimited:
            return true
        default:
            return false
        }
    }

    private func retryDelay(attempt: Int, lastError: (any Error)?) -> Double {
        if let error = lastError as? TestGitHubError,
           case .rateLimited(let retryAfter) = error,
           let seconds = retryAfter {
            return min(Double(seconds), 32.0)
        }
        let base = pow(2.0, Double(attempt - 1))
        let jitter = base * Double.random(in: -0.2...0.2)
        return min(base + jitter, 32.0)
    }
}

// MARK: - URL Normalization (from GitHubClient.swift)

private func normalizeToRawURL(_ url: URL) -> URL {
    let host = url.host?.lowercased() ?? ""
    let pathComponents = url.pathComponents.filter { $0 != "/" }

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

// MARK: - Git Blob SHA (from PersonalRepoSync.swift)

private func gitBlobSHA(for content: String) -> String {
    let data = Data(content.utf8)
    let header = "blob \(data.count)\0"
    var blob = Data(header.utf8)
    blob.append(data)

    var digest = [UInt8](repeating: 0, count: 20)
    blob.withUnsafeBytes { buffer in
        _ = CC_SHA1(buffer.baseAddress, CC_LONG(buffer.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}

// =============================================================================
// MARK: - Tests
// =============================================================================

// MARK: - ETag Caching Tests

@Suite("GitHubClient ETag Caching")
struct ETagCachingTests {
    init() {
        MockGitHubProtocol.reset()
    }

    @Test("Sends If-None-Match when ETag is cached")
    func sendsIfNoneMatch() async throws {
        let responseData = Data("hello".utf8)
        var callCount = 0
        MockGitHubProtocol.requestHandler = { _ in
            callCount += 1
            if callCount == 1 {
                return (responseData, 200, ["ETag": "\"abc123\""])
            }
            // Second call: 304 Not Modified
            return (Data(), 304, [:])
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/repos/test/test/contents/python")!

        // First request — populates cache
        _ = try await client.perform(URLRequest(url: url))

        // Second request — should include If-None-Match
        _ = try await client.perform(URLRequest(url: url))

        #expect(MockGitHubProtocol.requestLog.count == 2)
        let secondRequest = MockGitHubProtocol.requestLog[1]
        #expect(secondRequest.value(forHTTPHeaderField: "If-None-Match") == "\"abc123\"")
    }

    @Test("Returns cached data on 304 Not Modified")
    func returnsCachedDataOn304() async throws {
        let originalData = Data("original content".utf8)
        var callCount = 0
        MockGitHubProtocol.requestHandler = { _ in
            callCount += 1
            if callCount == 1 {
                return (originalData, 200, ["ETag": "\"v1\""])
            }
            return (Data(), 304, [:])
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/test")!

        let (data1, _) = try await client.perform(URLRequest(url: url))
        let (data2, _) = try await client.perform(URLRequest(url: url))

        #expect(data1 == originalData)
        #expect(data2 == originalData)
    }

    @Test("Updates cache on new 200 response")
    func updatesCacheOnNew200() async throws {
        var callCount = 0
        MockGitHubProtocol.requestHandler = { _ in
            callCount += 1
            switch callCount {
            case 1: return (Data("v1".utf8), 200, ["ETag": "\"etag-v1\""])
            case 2: return (Data("v2".utf8), 200, ["ETag": "\"etag-v2\""])
            default: return (Data(), 304, [:])
            }
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/test")!

        _ = try await client.perform(URLRequest(url: url))
        _ = try await client.perform(URLRequest(url: url))

        // Third request should send etag-v2, not etag-v1
        _ = try await client.perform(URLRequest(url: url))

        let thirdRequest = MockGitHubProtocol.requestLog[2]
        #expect(thirdRequest.value(forHTTPHeaderField: "If-None-Match") == "\"etag-v2\"")
    }

    @Test("Does not cache non-GET requests")
    func doesNotCacheNonGET() async throws {
        MockGitHubProtocol.requestHandler = { _ in
            (Data("ok".utf8), 200, ["ETag": "\"should-not-cache\""])
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/test")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        _ = try await client.perform(request)

        // Second PUT should NOT have If-None-Match
        _ = try await client.perform(request)

        let secondRequest = MockGitHubProtocol.requestLog[1]
        #expect(secondRequest.value(forHTTPHeaderField: "If-None-Match") == nil)
    }
}

// MARK: - Retry Tests

@Suite("GitHubClient Retry")
struct RetryTests {
    init() {
        MockGitHubProtocol.reset()
    }

    @Test("Retries on 5xx server error")
    func retriesOn5xx() async throws {
        var callCount = 0
        MockGitHubProtocol.requestHandler = { _ in
            callCount += 1
            if callCount == 1 {
                return (Data(), 500, [:])
            }
            return (Data("ok".utf8), 200, [:])
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/test")!
        let (data, _) = try await client.perform(URLRequest(url: url))

        #expect(MockGitHubProtocol.requestLog.count == 2)
        #expect(String(data: data, encoding: .utf8) == "ok")
    }

    @Test("Does not retry on 4xx client error")
    func doesNotRetryOn4xx() async throws {
        MockGitHubProtocol.requestHandler = { _ in
            (Data(), 404, [:])
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/test")!

        do {
            _ = try await client.perform(URLRequest(url: url))
            Issue.record("Expected notFound error")
        } catch let error as TestGitHubError {
            #expect(error == .notFound)
        }

        #expect(MockGitHubProtocol.requestLog.count == 1)
    }

    @Test("Respects max 7 attempts")
    func respectsMaxAttempts() async throws {
        MockGitHubProtocol.requestHandler = { _ in
            (Data("error".utf8), 502, [:])
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/test")!

        do {
            _ = try await client.perform(URLRequest(url: url))
            Issue.record("Expected httpError")
        } catch let error as TestGitHubError {
            #expect(error == .httpError(statusCode: 502, message: "error"))
        }

        #expect(MockGitHubProtocol.requestLog.count == 7)
    }

    @Test("Does not retry POST requests")
    func doesNotRetryPOST() async throws {
        MockGitHubProtocol.requestHandler = { _ in
            (Data("error".utf8), 500, [:])
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/user/repos")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        do {
            _ = try await client.perform(request)
            Issue.record("Expected httpError")
        } catch let error as TestGitHubError {
            #expect(error == .httpError(statusCode: 500, message: "error"))
        }

        #expect(MockGitHubProtocol.requestLog.count == 1)
    }

    @Test("Retries on rate limit with retry-after: 0")
    func retriesOnRateLimit() async throws {
        var callCount = 0
        MockGitHubProtocol.requestHandler = { _ in
            callCount += 1
            if callCount == 1 {
                return (Data(), 429, ["retry-after": "0"])
            }
            return (Data("ok".utf8), 200, [:])
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/test")!
        let (data, _) = try await client.perform(URLRequest(url: url))

        #expect(MockGitHubProtocol.requestLog.count == 2)
        #expect(String(data: data, encoding: .utf8) == "ok")
    }

    @Test("Retries PUT requests (idempotent)")
    func retriesPUT() async throws {
        var callCount = 0
        MockGitHubProtocol.requestHandler = { _ in
            callCount += 1
            if callCount == 1 {
                return (Data(), 500, [:])
            }
            return (Data("ok".utf8), 200, [:])
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/test")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let (data, _) = try await client.perform(request)

        #expect(MockGitHubProtocol.requestLog.count == 2)
        #expect(String(data: data, encoding: .utf8) == "ok")
    }

    @Test("Retries DELETE requests (idempotent)")
    func retriesDELETE() async throws {
        var callCount = 0
        MockGitHubProtocol.requestHandler = { _ in
            callCount += 1
            if callCount == 1 {
                return (Data(), 502, [:])
            }
            return (Data("ok".utf8), 200, [:])
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/test")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, _) = try await client.perform(request)

        #expect(MockGitHubProtocol.requestLog.count == 2)
        #expect(String(data: data, encoding: .utf8) == "ok")
    }

    @Test("Does not retry 403 permission denied (not rate limit)")
    func doesNotRetry403Permission() async throws {
        MockGitHubProtocol.requestHandler = { _ in
            (Data("Forbidden".utf8), 403, ["x-ratelimit-remaining": "50"])
        }

        let client = TestGitHubClient(session: makeMockSession())
        let url = URL(string: "https://api.github.com/test")!

        do {
            _ = try await client.perform(URLRequest(url: url))
            Issue.record("Expected permissionDenied")
        } catch let error as TestGitHubError {
            #expect(error == .permissionDenied(message: "Forbidden"))
        }

        #expect(MockGitHubProtocol.requestLog.count == 1)
    }
}

// MARK: - URL Normalization Tests

@Suite("GitHub URL Normalization")
struct URLNormalizationTests {
    @Test("Converts blob URL to raw URL")
    func blobToRaw() {
        let url = URL(string: "https://github.com/owner/repo/blob/main/python/delay.py")!
        let raw = normalizeToRawURL(url)
        #expect(raw.absoluteString == "https://raw.githubusercontent.com/owner/repo/main/python/delay.py")
    }

    @Test("Converts raw URL format to raw URL")
    func rawToRaw() {
        let url = URL(string: "https://github.com/owner/repo/raw/main/test.py")!
        let raw = normalizeToRawURL(url)
        #expect(raw.absoluteString == "https://raw.githubusercontent.com/owner/repo/main/test.py")
    }

    @Test("Converts gist URL to raw URL")
    func gistToRaw() {
        let url = URL(string: "https://gist.github.com/user/abc123")!
        let raw = normalizeToRawURL(url)
        #expect(raw.absoluteString == "https://gist.githubusercontent.com/user/abc123/raw")
    }

    @Test("Passes through non-GitHub URLs unchanged")
    func nonGitHubPassthrough() {
        let url = URL(string: "https://example.com/file.py")!
        let result = normalizeToRawURL(url)
        #expect(result == url)
    }

    @Test("Passes through already-raw URLs unchanged")
    func alreadyRawPassthrough() {
        let url = URL(string: "https://raw.githubusercontent.com/owner/repo/main/file.py")!
        let result = normalizeToRawURL(url)
        #expect(result == url)
    }
}

// MARK: - Git Blob SHA Tests

@Suite("Git Blob SHA")
struct GitBlobSHATests {
    @Test("Computes correct SHA for known content")
    func knownContent() {
        // echo -n "hello" | git hash-object --stdin = b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0
        let sha = gitBlobSHA(for: "hello")
        #expect(sha == "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
    }

    @Test("Empty string produces valid SHA")
    func emptyString() {
        // echo -n "" | git hash-object --stdin = e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
        let sha = gitBlobSHA(for: "")
        #expect(sha == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    @Test("Different content produces different SHAs")
    func differentContent() {
        let sha1 = gitBlobSHA(for: "foo")
        let sha2 = gitBlobSHA(for: "bar")
        #expect(sha1 != sha2)
    }
}
