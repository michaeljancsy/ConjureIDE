import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "ExportRegistry")

/// Tracks exported AU plugins in a local JSON registry.
///
/// Registry file: `export-registry.json` in the App Group container.
final class ExportRegistry {
    struct Entry: Codable, Equatable {
        let name: String
        let subtype: String
        let bundleId: String
        let exportDate: Date
        let language: String
    }

    private(set) var entries: [Entry] = []
    let registryURL: URL

    init() {
        registryURL = AppGroupContainer.url
            .appendingPathComponent("export-registry.json")
        load()
    }

    /// Testable initializer with explicit registry file URL.
    init(registryURL: URL) {
        self.registryURL = registryURL
        load()
    }

    /// All subtypes currently in the registry.
    func allSubtypes() -> Set<String> {
        Set(entries.map(\.subtype))
    }

    /// Registers a new export entry, replacing any existing entry with the same subtype.
    func register(_ entry: Entry) {
        entries.removeAll { $0.subtype == entry.subtype }
        entries.append(entry)
        save()
    }

    /// Removes the entry with the given subtype.
    @discardableResult
    func remove(subtype: String) -> Entry? {
        guard let idx = entries.firstIndex(where: { $0.subtype == subtype }) else { return nil }
        let removed = entries.remove(at: idx)
        save()
        return removed
    }

    /// Finds the entry for the given preset name, if any.
    func entry(forName name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    // MARK: - Persistence

    func load() {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            entries = []
            return
        }
        do {
            let data = try Data(contentsOf: registryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([Entry].self, from: data)
        } catch {
            log.error("Failed to load export registry: \(error.localizedDescription, privacy: .public)")
            SentryHelper.captureError(error, category: "export.registry")
            entries = []
        }
    }

    func save() {
        do {
            let dir = registryURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            log.error("Failed to save export registry: \(error.localizedDescription, privacy: .public)")
            SentryHelper.captureError(error, category: "export.registry")
        }
    }
}
