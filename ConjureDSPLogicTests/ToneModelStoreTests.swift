import Foundation
import Testing

// Local copy of ToneMetadata for testing (test target can't import AU extension module)

private struct ToneMetadata: Codable {
    let toneId: String
    let toneName: String
    let toneUrl: String?
    let gear: String
    let author: String
    let tags: [String]?
    let makes: [String]?
    let models: [ModelMetadata]
}

private struct ModelMetadata: Codable {
    let modelId: String
    let modelName: String
    let modelSize: String
    let architectureVersion: String?
    let downloadDate: Date
}

@Suite("ToneModelStore metadata persistence")
struct ToneModelStoreTests {

    // MARK: - Tags/Makes Serialization

    @Test("Metadata with tags and makes roundtrips through JSON")
    func metadataWithTagsAndMakesRoundtrips() throws {
        let original = ToneMetadata(
            toneId: "34",
            toneName: "Marshall JCM800",
            toneUrl: "https://tone3000.com/tones/34",
            gear: "amp",
            author: "testuser",
            tags: ["rock", "metal", "nam"],
            makes: ["Marshall", "JCM800"],
            models: [
                ModelMetadata(
                    modelId: "82524",
                    modelName: "Standard",
                    modelSize: "standard",
                    architectureVersion: "2",
                    downloadDate: Date(timeIntervalSince1970: 1700000000)
                ),
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToneMetadata.self, from: data)

        #expect(decoded.toneId == "34")
        #expect(decoded.toneName == "Marshall JCM800")
        #expect(decoded.gear == "amp")
        #expect(decoded.author == "testuser")
        #expect(decoded.tags == ["rock", "metal", "nam"])
        #expect(decoded.makes == ["Marshall", "JCM800"])
        #expect(decoded.models.count == 1)
        #expect(decoded.models[0].modelId == "82524")
        #expect(decoded.models[0].architectureVersion == "2")
    }

    @Test("Metadata without tags/makes decodes with nil (backward compatibility)")
    func metadataWithoutTagsAndMakesDecodesAsNil() throws {
        // Simulate a metadata.json written before tags/makes were added
        let json = """
        {
            "toneId": "21",
            "toneName": "Fender Twin",
            "gear": "amp",
            "author": "olduser",
            "models": [{
                "modelId": "82686",
                "modelName": "Standard",
                "modelSize": "standard",
                "downloadDate": 1700000000
            }]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ToneMetadata.self, from: json)

        #expect(decoded.toneId == "21")
        #expect(decoded.toneName == "Fender Twin")
        #expect(decoded.tags == nil)
        #expect(decoded.makes == nil)
        #expect(decoded.models.count == 1)
    }

    @Test("Metadata with empty tags/makes arrays decodes correctly")
    func metadataWithEmptyTagsAndMakes() throws {
        let original = ToneMetadata(
            toneId: "99",
            toneName: "No Tags Tone",
            toneUrl: nil,
            gear: "pedal",
            author: "someone",
            tags: [],
            makes: [],
            models: []
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToneMetadata.self, from: data)

        #expect(decoded.tags == [])
        #expect(decoded.makes == [])
        #expect(decoded.models.isEmpty)
    }

    @Test("Metadata with multiple models preserves all entries")
    func metadataMultipleModels() throws {
        let original = ToneMetadata(
            toneId: "44209",
            toneName: "Mesa Boogie",
            toneUrl: "https://tone3000.com/tones/44209",
            gear: "full-rig",
            author: "rigbuilder",
            tags: ["metal"],
            makes: ["Mesa"],
            models: [
                ModelMetadata(modelId: "233039", modelName: "Standard", modelSize: "standard",
                              architectureVersion: "1",
                              downloadDate: Date(timeIntervalSince1970: 1700000000)),
                ModelMetadata(modelId: "234539", modelName: "Lite", modelSize: "lite",
                              architectureVersion: "2",
                              downloadDate: Date(timeIntervalSince1970: 1700000100)),
                ModelMetadata(modelId: "234548", modelName: "Feather", modelSize: "feather",
                              architectureVersion: nil,
                              downloadDate: Date(timeIntervalSince1970: 1700000200)),
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToneMetadata.self, from: data)

        #expect(decoded.models.count == 3)
        #expect(decoded.models[0].modelName == "Standard")
        #expect(decoded.models[1].modelName == "Lite")
        #expect(decoded.models[2].modelName == "Feather")
        #expect(decoded.models[0].architectureVersion == "1")
        #expect(decoded.models[2].architectureVersion == nil)
    }

    @Test("Legacy metadata.json without architectureVersion still decodes")
    func legacyMetadataDecodes() throws {
        // Written by builds that predate architecture tracking.
        let json = """
        {
            "toneId": "19",
            "toneName": "Fender Super Reverb",
            "gear": "amp",
            "author": "someone",
            "models": [
                {
                    "modelId": "51",
                    "modelName": "Standard",
                    "modelSize": "standard",
                    "downloadDate": 700000000
                }
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ToneMetadata.self, from: json)
        #expect(decoded.models.count == 1)
        #expect(decoded.models[0].architectureVersion == nil)
    }
}
