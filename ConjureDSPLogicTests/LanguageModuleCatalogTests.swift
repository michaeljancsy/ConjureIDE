//
//  LanguageModuleCatalogTests.swift
//  ConjureDSPLogicTests
//
//  Round-trips the catalog/manifest/IPC Codable schemas used by
//  LanguageModuleManager (extension) and LanguageDownloader (terminal).
//  These are pure-data tests — they don't hit the filesystem or network.
//

import Foundation
import Testing

@Suite("Language module catalog")
struct LanguageModuleCatalogTests {

    @Test("Catalog decodes known fixture")
    func decodesCatalogFixture() throws {
        let json = """
        {
          "schemaVersion": 1,
          "modules": {
            "python": {
              "version": "3.14.3",
              "sizeMB": 303,
              "sha256": "deadbeef",
              "minApp": "1.0.15",
              "url": null,
              "licenseGate": null,
              "description": "Free-threaded Python 3.14 + numpy + scipy"
            },
            "cmajor": {
              "version": "1.0.0",
              "sizeMB": 80,
              "sha256": "cafebabe",
              "minApp": "1.0.15",
              "url": "https://example.com/cmajor-1.0.0.tar.gz",
              "licenseGate": "cmajor-commercial",
              "description": null
            }
          }
        }
        """.data(using: .utf8)!

        let catalog = try JSONDecoder().decode(LanguageModuleCatalog.self, from: json)
        #expect(catalog.schemaVersion == 1)
        #expect(catalog.modules.count == 2)

        let python = try #require(catalog.modules["python"])
        #expect(python.version == "3.14.3")
        #expect(python.sizeMB == 303)
        #expect(python.url == nil)
        #expect(python.licenseGate == nil)

        let cmajor = try #require(catalog.modules["cmajor"])
        #expect(cmajor.url == "https://example.com/cmajor-1.0.0.tar.gz")
        #expect(cmajor.licenseGate == "cmajor-commercial")
    }

    @Test("Catalog round-trip preserves all fields")
    func catalogRoundTrip() throws {
        let original = LanguageModuleCatalog(
            schemaVersion: 1,
            modules: [
                "lua": LanguageModuleSpec(
                    version: "2.1-beta3",
                    sizeMB: 1.2,
                    sha256: "abc123",
                    minApp: "1.0.15",
                    url: nil,
                    licenseGate: nil,
                    description: "LuaJIT 2.1 for scripting"
                )
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LanguageModuleCatalog.self, from: data)
        #expect(decoded.modules["lua"]?.version == "2.1-beta3")
        #expect(decoded.modules["lua"]?.sizeMB == 1.2)
        #expect(decoded.modules["lua"]?.description == "LuaJIT 2.1 for scripting")
    }

    @Test("Installed manifest round-trip")
    func installedManifestRoundTrip() throws {
        let manifest = InstalledLanguageModuleManifest(
            name: "libpd",
            version: "0.14.1",
            installedAt: 1_712_345_678.0,
            sha256: "feedface",
            installedBytes: 5_242_880,
            entrypoints: ["dylib": "lib/libpd.dylib"]
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(InstalledLanguageModuleManifest.self, from: data)
        #expect(decoded.name == "libpd")
        #expect(decoded.installedBytes == 5_242_880)
        #expect(decoded.entrypoints["dylib"] == "lib/libpd.dylib")
    }

    @Test("IPC request/result encode with stable keys")
    func ipcPayloadsEncodeStably() throws {
        let req = LanguageInstallRequest(
            requestId: "req-1",
            moduleName: "python",
            version: "3.14.3",
            url: "https://example.com/python.tar.gz",
            sha256: "deadbeef",
            timestamp: 1_712_345_678.0
        )
        let data = try JSONEncoder().encode(req)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"requestId\":\"req-1\""))
        #expect(json.contains("\"moduleName\":\"python\""))
        #expect(json.contains("\"sha256\":\"deadbeef\""))

        let result = LanguageInstallResult(
            requestId: "req-1",
            moduleName: "python",
            success: false,
            error: "boom",
            timestamp: 1_712_345_679.0
        )
        let resultData = try JSONEncoder().encode(result)
        let resultDecoded = try JSONDecoder().decode(LanguageInstallResult.self, from: resultData)
        #expect(resultDecoded.success == false)
        #expect(resultDecoded.error == "boom")
    }

    @Test("Default catalog URL is HTTPS to updates.conjuredsp.com")
    func defaultCatalogURLIsProduction() {
        #expect(LanguageCatalog.defaultCatalogURL.scheme == "https")
        #expect(LanguageCatalog.defaultCatalogURL.host == "updates.conjuredsp.com")
        #expect(LanguageCatalog.defaultCatalogURL.path.hasSuffix("/catalog.json"))
    }

    @Test("UserDefaults override is respected when set")
    func catalogURLOverride() {
        let key = "ConjureDSPLanguageCatalogURL"
        let override = "http://localhost:8080/catalog.json"
        UserDefaults.standard.set(override, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(LanguageCatalog.resolvedCatalogURL().absoluteString == override)
    }
}
