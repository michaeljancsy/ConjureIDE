//
//  Tone3000Models.swift
//  ConjureDSPExtension
//
//  Codable types for the tone3000 API (https://github.com/tone-3000/api).
//

import Foundation

// MARK: - API Response Types

struct Tone: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let user: ToneUser?
    let gear: String?
    let images: [ToneImage]?
    let sizes: [String]?
    let makes: [String]?
    let tags: [String]?
    let modelCount: Int?
    let downloadCount: Int?
    let favoriteCount: Int?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description, user, gear, images, sizes, makes, tags, url
        case modelCount = "model_count"
        case downloadCount = "download_count"
        case favoriteCount = "favorite_count"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Tone, rhs: Tone) -> Bool { lhs.id == rhs.id }
}

struct ToneUser: Codable, Hashable {
    let id: String
    let username: String
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case avatarUrl = "avatar_url"
    }
}

struct ToneImage: Codable, Hashable {
    let url: String?
}

struct ToneModel: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let size: String?
    let modelUrl: String?
    let toneId: String?

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
