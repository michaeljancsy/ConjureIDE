import Testing
import Foundation

// Local copies of the Codable types for testing (test target can't import AU extension module)

private struct Tone: Codable, Identifiable {
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
    let downloadCount: Int?
    let favoritesCount: Int?
    let downloadsCount: Int?
    let favoriteCount: Int?
    let url: String?
    let platform: String?
    let createdAt: String?
    let updatedAt: String?
    let a1ModelsCount: Int?
    let a2ModelsCount: Int?
    let customModelsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, description, user, gear, images, sizes, makes, tags, url, platform
        case modelsCount = "models_count"
        case downloadsCount = "downloads_count"
        case favoritesCount = "favorites_count"
        case downloadCount = "download_count"
        case favoriteCount = "favorite_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case a1ModelsCount = "a1_models_count"
        case a2ModelsCount = "a2_models_count"
        case customModelsCount = "custom_models_count"
    }
}

/// The API returns `id` as an integer, but we model it as a string for Identifiable.
private enum IntOrString: Codable, Hashable {
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

private struct ToneUser: Codable, Hashable {
    let id: String
    let username: String
    let avatarUrl: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id, username, url
        case avatarUrl = "avatar_url"
    }
}

/// Tags and makes come as `[{"name": "..."}]` from the API.
private struct TagOrMake: Codable, Hashable {
    let name: String
}

private struct ToneSearchResult: Codable {
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

    var items: [Tone] { data ?? [] }
}

private struct ToneModel: Codable, Identifiable, Hashable {
    let id: IntOrString
    let name: String?
    let size: String?
    let modelUrl: String?
    let toneId: IntOrString?
    let architectureVersion: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case modelUrl = "model_url"
        case toneId = "tone_id"
        case architectureVersion = "architecture_version"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ToneModel, rhs: ToneModel) -> Bool { lhs.id == rhs.id }
}

private struct ToneModelsResult: Codable {
    let data: [ToneModel]?
    var items: [ToneModel] { data ?? [] }
}

// MARK: - Tests

@Suite("tone3000 API response parsing")
struct Tone3000DecodingTests {

    @Test("Decode search results with real API response shape")
    func decodeSearchResults() throws {
        let json = """
        {
            "data": [
                {
                    "id": 28135,
                    "title": "Peavey",
                    "description": "Peavey Invective 4x12 v30 58+160",
                    "tags": [{"name": "metal"}, {"name": "nam"}],
                    "makes": [],
                    "gear": "full-rig",
                    "models_count": 1,
                    "favorites_count": 8,
                    "downloads_count": 600,
                    "created_at": "2025-04-27T23:57:27.583672+00:00",
                    "updated_at": "2025-04-27T23:57:27.583672+00:00",
                    "platform": "nam",
                    "images": ["https://example.com/tone.png"],
                    "user_id": "fecebf0a-ce34-45a9-9e4c-a2dfc7999d7e",
                    "user": {
                        "username": "cristophercordoba90",
                        "avatar_url": "https://example.com/avatar.jpg",
                        "id": "fecebf0a-ce34-45a9-9e4c-a2dfc7999d7e",
                        "url": "https://www.tone3000.com/cristophercordoba90"
                    },
                    "url": "https://www.tone3000.com/peavey-28135"
                }
            ],
            "page": 1,
            "page_size": 2,
            "total": 328,
            "total_pages": 164
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ToneSearchResult.self, from: json)

        #expect(result.items.count == 1)
        #expect(result.total == 328)
        #expect(result.page == 1)
        #expect(result.pageSize == 2)
        #expect(result.totalPages == 164)

        let tone = result.items[0]
        #expect(tone.id.stringValue == "28135")
        #expect(tone.title == "Peavey")
        #expect(tone.description == "Peavey Invective 4x12 v30 58+160")
        #expect(tone.gear == "full-rig")
        #expect(tone.modelsCount == 1)
        #expect(tone.favoritesCount == 8)
        #expect(tone.downloadsCount == 600)
        #expect(tone.platform == "nam")
        #expect(tone.user?.username == "cristophercordoba90")
        #expect(tone.user?.avatarUrl == "https://example.com/avatar.jpg")
        #expect(tone.tags?.count == 2)
        #expect(tone.tags?.first?.name == "metal")
        #expect(tone.makes?.isEmpty == true)
        #expect(tone.images?.first == "https://example.com/tone.png")
    }

    @Test("Decode tone with null optional fields")
    func decodeToneWithNulls() throws {
        let json = """
        {
            "data": [{
                "id": 999,
                "title": "Minimal Tone",
                "description": null,
                "tags": null,
                "makes": null,
                "gear": "amp",
                "models_count": 0,
                "favorites_count": 0,
                "downloads_count": 0,
                "platform": "nam",
                "images": null,
                "user": null,
                "url": null
            }],
            "page": 1,
            "page_size": 10,
            "total": 1,
            "total_pages": 1
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ToneSearchResult.self, from: json)
        #expect(result.items.count == 1)
        let tone = result.items[0]
        #expect(tone.title == "Minimal Tone")
        #expect(tone.description == nil)
        #expect(tone.user == nil)
        #expect(tone.tags == nil)
        #expect(tone.images == nil)
    }

    @Test("Decode empty search results")
    func decodeEmptyResults() throws {
        let json = """
        {"data": [], "page": 1, "page_size": 10, "total": 0, "total_pages": 0}
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ToneSearchResult.self, from: json)
        #expect(result.items.isEmpty)
        #expect(result.total == 0)
    }

    @Test("Decode tone with string id")
    func decodeToneWithStringId() throws {
        let json = """
        {
            "data": [{
                "id": "abc-123",
                "title": "String ID Tone",
                "gear": "pedal",
                "models_count": 1,
                "favorites_count": 0,
                "downloads_count": 0,
                "platform": "nam"
            }],
            "page": 1, "page_size": 10, "total": 1, "total_pages": 1
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ToneSearchResult.self, from: json)
        #expect(result.items[0].id.stringValue == "abc-123")
    }

    @Test("Decode models response")
    func decodeModelsResponse() throws {
        let json = """
        {
            "data": [
                {
                    "id": 45678,
                    "name": "Standard",
                    "size": "standard",
                    "model_url": "https://example.com/model.nam",
                    "tone_id": 28135,
                    "created_at": "2025-04-27T23:57:27.583672+00:00"
                }
            ],
            "page": 1, "page_size": 25, "total": 1, "total_pages": 1
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ToneModelsResult.self, from: json)
        #expect(result.items.count == 1)
        #expect(result.items[0].name == "Standard")
        #expect(result.items[0].size == "standard")
        #expect(result.items[0].modelUrl == "https://example.com/model.nam")
        #expect(result.items[0].id.stringValue == "45678")
        // Pre-A2 responses have no architecture_version — decodes as nil.
        #expect(result.items[0].architectureVersion == nil)
    }

    @Test("Decode A2 model with architecture_version")
    func decodeA2Model() throws {
        let json = """
        {
            "data": [
                {
                    "id": 900001,
                    "name": "A2 Capture",
                    "size": "standard",
                    "model_url": "https://example.com/a2.nam",
                    "tone_id": 28135,
                    "architecture_version": "2"
                },
                {
                    "id": 900002,
                    "name": "Legacy Capture",
                    "size": "lite",
                    "model_url": "https://example.com/a1.nam",
                    "tone_id": 28135,
                    "architecture_version": "1"
                },
                {
                    "id": 900003,
                    "name": "Some IR",
                    "size": null,
                    "model_url": "https://example.com/x.wav",
                    "tone_id": 28135,
                    "architecture_version": null
                }
            ],
            "page": 1, "page_size": 25, "total": 3, "total_pages": 1
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ToneModelsResult.self, from: json)
        #expect(result.items.count == 3)
        #expect(result.items[0].architectureVersion == "2")
        #expect(result.items[1].architectureVersion == "1")
        #expect(result.items[2].architectureVersion == nil)
    }

    @Test("Decode tone with per-architecture model counts")
    func decodeToneArchitectureCounts() throws {
        let json = """
        {
            "id": 28135,
            "title": "Test Amp",
            "models_count": 4,
            "a1_models_count": 2,
            "a2_models_count": 2,
            "custom_models_count": 0
        }
        """.data(using: .utf8)!

        let tone = try JSONDecoder().decode(Tone.self, from: json)
        #expect(tone.a1ModelsCount == 2)
        #expect(tone.a2ModelsCount == 2)
        #expect(tone.customModelsCount == 0)
    }

    @Test("Decode user response")
    func decodeUserResponse() throws {
        let json = """
        {
            "id": "fecebf0a-ce34-45a9-9e4c-a2dfc7999d7e",
            "username": "testuser",
            "avatar_url": "https://example.com/avatar.jpg",
            "url": "https://www.tone3000.com/testuser"
        }
        """.data(using: .utf8)!

        let user = try JSONDecoder().decode(ToneUser.self, from: json)
        #expect(user.username == "testuser")
        #expect(user.id == "fecebf0a-ce34-45a9-9e4c-a2dfc7999d7e")
        #expect(user.avatarUrl == "https://example.com/avatar.jpg")
    }

    @Test("Models response caching pattern — nil check prevents refetch")
    func modelsCachingPattern() throws {
        // Simulates the caching pattern added to ToneBrowserView.fetchModels
        var toneModels: [String: [ToneModel]] = [:]

        // First fetch populates the cache
        let toneId = "28135"
        #expect(toneModels[toneId] == nil, "Initially empty")

        // Simulate fetch
        let models = [ToneModel(id: .int(45678), name: "Standard", size: "standard",
                                modelUrl: "https://example.com/model.nam", toneId: .int(28135),
                                architectureVersion: "2")]
        toneModels[toneId] = models

        // Second "fetch" should be skipped due to cache hit
        #expect(toneModels[toneId] != nil, "Cache should be populated")
        #expect(toneModels[toneId]?.count == 1, "Should have one cached model")

        // The guard pattern: if toneModels[toneId] != nil { return }
        var fetchCount = 0
        func simulatedFetch() {
            if toneModels[toneId] != nil { return }
            fetchCount += 1
        }
        simulatedFetch()
        simulatedFetch()
        #expect(fetchCount == 0, "Cache hit should prevent re-fetch")
    }

    @Test("Tags and makes decode as name objects")
    func decodeTagsAndMakes() throws {
        let json = """
        {
            "data": [{
                "id": 1,
                "title": "Tagged Tone",
                "gear": "amp",
                "models_count": 1,
                "favorites_count": 0,
                "downloads_count": 0,
                "platform": "nam",
                "tags": [{"name": "rock"}, {"name": "metal"}, {"name": "nam"}],
                "makes": [{"name": "Marshall"}, {"name": "JCM800"}]
            }],
            "page": 1, "page_size": 10, "total": 1, "total_pages": 1
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ToneSearchResult.self, from: json)
        let tone = result.items[0]
        #expect(tone.tags?.count == 3)
        #expect(tone.tags?[0].name == "rock")
        #expect(tone.makes?.count == 2)
        #expect(tone.makes?[0].name == "Marshall")
    }
}
