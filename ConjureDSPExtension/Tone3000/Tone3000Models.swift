//
//  Tone3000Models.swift
//  ConjureDSPExtension
//
//  Codable types for the tone3000 API (https://github.com/tone-3000/api).
//

import Foundation

// MARK: - Flexible ID (API returns int, we need String for Identifiable)

/// The tone3000 API returns `id` as an integer. This enum decodes both int and string
/// so the types work regardless of API changes.
enum IntOrString: Codable, Hashable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }

    var stringValue: String {
        switch self {
        case .int(let v): return String(v)
        case .string(let v): return v
        }
    }
}

// MARK: - API Response Types

/// Tags and makes come as `[{"name": "..."}]` from the API.
struct TagOrMake: Codable, Hashable {
    let name: String
}

struct Tone: Codable, Identifiable, Hashable {
    let id: IntOrString
    let title: String
    let description: String?
    let user: ToneUser?
    let gear: String?
    let images: [String]?
    let sizes: [String]?
    let makes: [TagOrMake]?
    let tags: [TagOrMake]?
    let modelsCount: Int?
    let favoritesCount: Int?
    let downloadsCount: Int?
    let url: String?
    let platform: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description, user, gear, images, sizes, makes, tags, url, platform
        case modelsCount = "models_count"
        case favoritesCount = "favorites_count"
        case downloadsCount = "downloads_count"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Tone, rhs: Tone) -> Bool { lhs.id == rhs.id }
}

struct ToneUser: Codable, Hashable {
    let id: String
    let username: String
    let avatarUrl: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id, username, url
        case avatarUrl = "avatar_url"
    }
}

struct ToneModel: Codable, Identifiable, Hashable {
    let id: IntOrString
    let name: String?
    let size: String?
    let modelUrl: String?
    let toneId: IntOrString?

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case modelUrl = "model_url"
        case toneId = "tone_id"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ToneModel, rhs: ToneModel) -> Bool { lhs.id == rhs.id }
}

struct ToneSearchResult: Codable {
    let data: [Tone]?
    let total: Int?
    let page: Int?
    let pageSize: Int?
    let totalPages: Int?

    enum CodingKeys: String, CodingKey {
        case data, total, page
        case pageSize = "page_size"
        case totalPages = "total_pages"
    }

    /// Convenience: the actual tone list (handles nil from API).
    var items: [Tone] { data ?? [] }
}

struct ToneModelsResult: Codable {
    let data: [ToneModel]?

    /// Convenience: the actual model list (handles nil from API).
    var items: [ToneModel] { data ?? [] }
}

// MARK: - Enums

enum ToneSort: String, CaseIterable {
    case bestMatch = "best-match"
    case newest = "newest"
    case oldest = "oldest"
    case trending = "trending"
    case downloadsAllTime = "downloads-all-time"

    var displayName: String {
        switch self {
        case .bestMatch: return "Best Match"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .trending: return "Trending"
        case .downloadsAllTime: return "Most Downloads"
        }
    }
}

enum ToneGear: String, CaseIterable {
    case amp
    case fullRig = "full-rig"
    case pedal
    case outboard
    case ir

    var displayName: String {
        switch self {
        case .amp: return "Amp"
        case .fullRig: return "Full Rig"
        case .pedal: return "Pedal"
        case .outboard: return "Outboard"
        case .ir: return "IR"
        }
    }
}

enum ToneSize: String, CaseIterable {
    case standard
    case lite
    case feather
    case nano

    var displayName: String { rawValue.capitalized }
}

// MARK: - Auth Response

struct Tone3000AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

struct Tone3000UserResponse: Codable {
    let id: String
    let username: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case avatarUrl = "avatar_url"
    }
}
