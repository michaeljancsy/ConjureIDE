//
//  Tone3000Client.swift
//  ConjureDSPExtension
//
//  HTTP client for the tone3000 API. Each user authenticates with their own
//  tone3000 account — no shared app API key, per-user rate limits (100 req/min).
//
//  Auth flow:
//  1. User logs in via WKWebView at /api/v1/auth?redirect_url=...
//  2. Redirect returns per-user api_key
//  3. Exchange api_key for access_token + refresh_token via POST /api/v1/auth/session
//  4. Tokens stored in Keychain
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "Tone3000")

@Observable
@MainActor
final class Tone3000Client {
    private static let baseURL = "https://www.tone3000.com/api/v1"
    private static let userAgent = "ConjureDSP-AUv3"

    // Keychain keys
    private static let accessTokenKey = "tone3000-access-token"
    private static let refreshTokenKey = "tone3000-refresh-token"
    private static let tokenExpiryKey = "tone3000-token-expiry"
    private static let usernameKey = "tone3000-username"

    // MARK: - Observable State

    private(set) var username: String?
    private(set) var isAuthenticated: Bool

    // MARK: - Initialization

    init() {
        username = KeychainHelper.load(key: Self.usernameKey)
        isAuthenticated = KeychainHelper.load(key: Self.accessTokenKey) != nil
    }

    // MARK: - Auth

    /// The URL to load in a WKWebView for user authentication.
    /// After login, tone3000 redirects to the redirect URL with an `api_key` parameter.
    static var authURL: URL {
        URL(string: "\(baseURL)/auth?redirect_url=conjuredsp://tone3000-auth")!
    }

    /// Exchange the per-user API key (from the OAuth redirect) for session tokens.
    func exchangeUserApiKey(_ userApiKey: String) async throws {
        let url = URL(string: "\(Self.baseURL)/auth/session")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(["api_key": userApiKey])

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response)

        let authResponse = try JSONDecoder().decode(Tone3000AuthResponse.self, from: data)

        // Store tokens
        try KeychainHelper.save(key: Self.accessTokenKey, value: authResponse.accessToken)
        try KeychainHelper.save(key: Self.refreshTokenKey, value: authResponse.refreshToken)
        let expiry = Date().addingTimeInterval(TimeInterval(authResponse.expiresIn))
        try KeychainHelper.save(key: Self.tokenExpiryKey, value: "\(expiry.timeIntervalSince1970)")

        isAuthenticated = true
        log.info("tone3000 auth succeeded")

        // Fetch username
        await fetchUsername()
    }

    /// Refresh the session tokens proactively.
    func refreshTokens() async throws {
        guard let refreshToken = KeychainHelper.load(key: Self.refreshTokenKey),
              let accessToken = KeychainHelper.load(key: Self.accessTokenKey) else {
            throw Tone3000Error.notAuthenticated
        }

        let url = URL(string: "\(Self.baseURL)/auth/session/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode([
            "access_token": accessToken,
            "refresh_token": refreshToken,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            // Refresh token expired — sign out
            signOut()
            throw Tone3000Error.sessionExpired
        }

        try checkResponse(response)

        let authResponse = try JSONDecoder().decode(Tone3000AuthResponse.self, from: data)
        try KeychainHelper.save(key: Self.accessTokenKey, value: authResponse.accessToken)
        try KeychainHelper.save(key: Self.refreshTokenKey, value: authResponse.refreshToken)
        let expiry = Date().addingTimeInterval(TimeInterval(authResponse.expiresIn))
        try KeychainHelper.save(key: Self.tokenExpiryKey, value: "\(expiry.timeIntervalSince1970)")

        log.info("tone3000 tokens refreshed")
    }

    func signOut() {
        KeychainHelper.delete(key: Self.accessTokenKey)
        KeychainHelper.delete(key: Self.refreshTokenKey)
        KeychainHelper.delete(key: Self.tokenExpiryKey)
        KeychainHelper.delete(key: Self.usernameKey)
        isAuthenticated = false
        username = nil
        log.info("tone3000 signed out")
    }

    /// The current access token, refreshing if needed. Returns nil if not authenticated.
    var accessToken: String? {
        get async {
            guard let token = KeychainHelper.load(key: Self.accessTokenKey) else { return nil }

            // Check if token is about to expire (within 60 seconds)
            if let expiryStr = KeychainHelper.load(key: Self.tokenExpiryKey),
               let expiryTs = Double(expiryStr) {
                let expiry = Date(timeIntervalSince1970: expiryTs)
                if expiry.timeIntervalSinceNow < 60 {
                    do {
                        try await refreshTokens()
                        return KeychainHelper.load(key: Self.accessTokenKey)
                    } catch {
                        log.error("Failed to refresh token: \(error.localizedDescription, privacy: .public)")
                        return nil
                    }
                }
            }

            return token
        }
    }

    // MARK: - Search / Browse

    func searchTones(
        query: String = "",
        sort: ToneSort = .bestMatch,
        gear: [ToneGear] = [],
        sizes: [ToneSize] = [],
        page: Int = 1
    ) async throws -> ToneSearchResult {
        var components = URLComponents(string: "\(Self.baseURL)/tones/search")!
        var queryItems = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "page_size", value: "15"),
            URLQueryItem(name: "sort", value: sort.rawValue),
        ]
        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        if !gear.isEmpty {
            queryItems.append(URLQueryItem(name: "gear", value: gear.map(\.rawValue).joined(separator: ",")))
        }
        if !sizes.isEmpty {
            queryItems.append(URLQueryItem(name: "sizes", value: sizes.map(\.rawValue).joined(separator: ",")))
        }
        components.queryItems = queryItems
        return try await authenticatedGet(url: components.url!)
    }

    func createdTones(page: Int = 1) async throws -> ToneSearchResult {
        let url = URL(string: "\(Self.baseURL)/tones/created?page=\(page)&page_size=15")!
        return try await authenticatedGet(url: url)
    }

    func favoritedTones(page: Int = 1) async throws -> ToneSearchResult {
        let url = URL(string: "\(Self.baseURL)/tones/favorited?page=\(page)&page_size=15")!
        return try await authenticatedGet(url: url)
    }

    func models(forToneId toneId: String) async throws -> [ToneModel] {
        let url = URL(string: "\(Self.baseURL)/models?tone_id=\(toneId)&page_size=25")!
        let result: ToneModelsResult = try await authenticatedGet(url: url)
        return result.items
    }

    // MARK: - Helpers

    private func authenticatedGet<T: Decodable>(url: URL) async throws -> T {
        guard let token = await accessToken else {
            throw Tone3000Error.notAuthenticated
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            // Token expired — try refresh once
            try await refreshTokens()
            guard let newToken = KeychainHelper.load(key: Self.accessTokenKey) else {
                throw Tone3000Error.notAuthenticated
            }
            var retryRequest = request
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            try checkResponse(retryResponse)
            return try JSONDecoder().decode(T.self, from: retryData)
        }

        try checkResponse(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func checkResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Tone3000Error.networkError("Invalid response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw Tone3000Error.httpError(httpResponse.statusCode)
        }
    }

    private func fetchUsername() async {
        do {
            let url = URL(string: "\(Self.baseURL)/user")!
            let user: Tone3000UserResponse = try await authenticatedGet(url: url)
            username = user.username
            try? KeychainHelper.save(key: Self.usernameKey, value: user.username)
        } catch {
            log.error("Failed to fetch username: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Errors

    enum Tone3000Error: LocalizedError {
        case notAuthenticated
        case sessionExpired
        case httpError(Int)
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Not signed in to tone3000"
            case .sessionExpired: return "tone3000 session expired — please sign in again"
            case .httpError(let code): return "tone3000 API error (HTTP \(code))"
            case .networkError(let msg): return "Network error: \(msg)"
            }
        }
    }
}
