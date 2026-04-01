//
//  RuntimeConfig.swift
//  ConjureDSPExportAUTemplateExtension
//

import Foundation

/// Rich metadata for a single exported parameter.
struct ExportParamMetadata: Codable {
    let name: String
    let key: String?
    let min: Float
    let max: Float
    let `default`: Float
    let unit: String
    let curve: String?
    let style: String?
    let options: [String]?

    var isToggle: Bool { style == "toggle" }
    var isChoice: Bool { style == "choice" }

    /// Denormalize a 0–1 value to the actual parameter range.
    func denormalize(_ normalized: Float) -> Float {
        let n = Swift.min(Swift.max(normalized, 0), 1)
        if curve == "log", min > 0, max > 0 {
            return min * powf(max / min, n)
        }
        return min + n * (max - min)
    }

    /// Normalize an actual value to 0–1.
    func normalize(_ actual: Float) -> Float {
        if curve == "log", min > 0, max > 0 {
            let ratio = Swift.max(actual / min, Float.ulpOfOne)
            let range = logf(max / min)
            guard range.magnitude > Float.ulpOfOne else { return 0 }
            return Swift.min(Swift.max(logf(ratio) / range, 0), 1)
        }
        let range = max - min
        guard range.magnitude > Float.ulpOfOne else { return 0 }
        return Swift.min(Swift.max((actual - min) / range, 0), 1)
    }
}

/// Metadata for an exported ConjureDSP preset, read from runtime-config.json in the AU bundle.
struct RuntimeConfig: Codable {
    let version: Int
    let language: String
    let presetName: String
    let exportDate: String?
    let bearBoneVersion: String?
    let paramCount: Int?
    let paramNames: [String]?
    /// Rich parameter metadata (name, min, max, unit, default, curve).
    /// When present, the AU builds parameters with real ranges instead of 0–1.
    let paramMetadata: [ExportParamMetadata]?
    /// Algorithmic latency in samples (0 = no latency).
    /// Used by the AU to report `AUAudioUnit.latency` for DAW delay compensation.
    let latencySamples: UInt32?
    /// Filename of an embedded NAM model (e.g., "model.nam").
    /// When present, the AU loads this from its bundle Resources and injects it.
    let namModelFile: String?

    /// Load from the given bundle's Resources.
    static func load(from bundle: Bundle) -> RuntimeConfig? {
        guard let url = bundle.url(forResource: "runtime-config", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RuntimeConfig.self, from: data)
    }

    /// Effective parameter count (defaults to 8).
    var effectiveParamCount: Int {
        if let metadata = paramMetadata, !metadata.isEmpty {
            return metadata.count
        }
        return paramCount ?? 8
    }

    /// Label for a parameter at the given index.
    func paramLabel(at index: Int) -> String {
        if let metadata = paramMetadata, index < metadata.count {
            return metadata[index].name
        }
        if let names = paramNames, index < names.count {
            return names[index]
        }
        return "Param \(index + 1)"
    }
}
