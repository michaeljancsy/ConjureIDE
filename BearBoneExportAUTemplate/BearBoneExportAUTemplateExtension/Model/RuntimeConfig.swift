//
//  RuntimeConfig.swift
//  BearBoneExportAUTemplateExtension
//

import Foundation

/// Metadata for an exported BearBone preset, read from runtime-config.json in the AU bundle.
struct RuntimeConfig: Codable {
    let version: Int
    let language: String
    let presetName: String
    let exportDate: String?
    let bearBoneVersion: String?
    let paramCount: Int?
    let paramNames: [String]?

    /// Load from the given bundle's Resources.
    static func load(from bundle: Bundle) -> RuntimeConfig? {
        guard let url = bundle.url(forResource: "runtime-config", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RuntimeConfig.self, from: data)
    }

    /// Effective parameter count (defaults to 8).
    var effectiveParamCount: Int {
        paramCount ?? 8
    }

    /// Label for a parameter at the given index.
    func paramLabel(at index: Int) -> String {
        if let names = paramNames, index < names.count {
            return names[index]
        }
        return "Param \(index + 1)"
    }
}
