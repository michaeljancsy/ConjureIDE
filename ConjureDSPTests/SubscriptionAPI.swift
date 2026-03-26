//
//  SubscriptionAPI.swift
//  ConjureDSPExtension
//
//  HTTP client for the subscription server's /activate and /verify endpoints.
//

import Foundation
import IOKit
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "SubscriptionAPI")

enum SubscriptionError: LocalizedError {
    case networkError(String)
    case serverError(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return "Network error: \(msg)"
        case .serverError(let code, let msg): return "Server error (\(code)): \(msg)"
        case .invalidResponse: return "Invalid server response"
        }
    }
}

enum SubscriptionAPI {
    #if DEBUG
    private static let baseURL = "https://api.conjuredsp.com"
    #else
    private static let baseURL = "https://api.conjuredsp.com"
    #endif

    /// Activate a subscription after Paddle checkout.
    /// Sends the transaction ID and machine ID, receives a signed token.
    static func activate(transactionID: String, machineID: String) async throws -> String {
        let url = URL(string: "\(baseURL)/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: String] = [
            "transaction_id": transactionID,
            "machine_id": machineID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw SubscriptionError.serverError(httpResponse.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw SubscriptionError.invalidResponse
        }

        return token
    }

    /// Verify/refresh an existing token.
    /// Sends the current token and machine ID, receives a fresh token.
    static func verify(token: String, machineID: String) async throws -> String {
        let url = URL(string: "\(baseURL)/verify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: String] = [
            "token": token,
            "machine_id": machineID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw SubscriptionError.serverError(httpResponse.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let freshToken = json["token"] as? String else {
            throw SubscriptionError.invalidResponse
        }

        return freshToken
    }

    /// Get a stable machine identifier using IOPlatformUUID.
    static func machineID() -> String {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                   IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }

        guard service != 0,
              let uuidData = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let uuid = uuidData as? String else {
            return UUID().uuidString
        }
        return uuid
    }
}
