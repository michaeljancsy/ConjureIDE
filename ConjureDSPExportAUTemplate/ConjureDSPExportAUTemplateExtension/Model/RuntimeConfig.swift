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
    var isInteger: Bool { style == "integer" }

    /// Denormalize a 0–1 value to the actual parameter range.
    /// Integer-styled params snap the result to the nearest whole number
    /// within `[min, max]`.
    func denormalize(_ normalized: Float) -> Float {
        let n = Swift.min(Swift.max(normalized, 0), 1)
        let raw: Float
        if curve == "log", min > 0, max > 0 {
            raw = min * powf(max / min, n)
        } else {
            raw = min + n * (max - min)
        }
        if isInteger {
            let lo = Swift.min(min, max)
            let hi = Swift.max(min, max)
            return Swift.min(Swift.max(raw.rounded(), lo), hi)
        }
        return raw
    }

    /// Normalize an actual value to 0–1.
    /// Integer-styled params round the input first so round-trips are stable.
    func normalize(_ actual: Float) -> Float {
        let actual = isInteger ? actual.rounded() : actual
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

/// UI block mirrored from the preset bundle's `manifest.json` when the preset
/// shipped a custom HTML/JS UI. When `entryHTML` resolves to a real file inside
/// the exported AU's Resources, the view controller renders that page instead
/// of the generic slider view.
struct RuntimeUIConfig: Codable {
    /// Relative path from the AU's `Resources/ui/` to the entry HTML.
    /// Defaults to `"index.html"` when omitted.
    let entryHTML: String?
    /// Preferred UI width in points (informational — the AU picks an actual
    /// size in `preferredContentSize`).
    let width: Int?
    /// Preferred UI height in points.
    let height: Int?
    /// Audio-frame forwarding rate the author requested (15 or 30). Not wired
    /// in the export template today — RMS/FFT frames are main-extension-only.
    let fps: Int?
    /// Whether the preset opted into audio frame delivery.
    let audioFrames: Bool?

    /// Entry relative to `Resources/ui/`, with a safe default.
    var resolvedEntryHTML: String {
        let raw = entryHTML?.trimmingCharacters(in: .whitespaces) ?? ""
        return raw.isEmpty ? "index.html" : raw
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
    /// True when the exporter copied a preset bundle's `ui/` directory into
    /// this AU's Resources. The view controller still verifies the entry HTML
    /// exists before switching away from the generic slider view.
    let hasCustomUI: Bool?
    /// Custom UI configuration copied from the source preset's manifest.
    let ui: RuntimeUIConfig?

    /// Load from the given bundle's Resources.
    static func load(from bundle: Bundle) -> RuntimeConfig? {
        guard let url = bundle.url(forResource: "runtime-config", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RuntimeConfig.self, from: data)
    }

    /// Resolve the custom UI entry HTML inside `bundle.resourceURL/ui/`, or
    /// `nil` if the preset didn't ship a custom UI or the file is missing.
    /// The view controller uses this as the sole gate for choosing custom
    /// UI over the generic slider view.
    func customUIEntryURL(in bundle: Bundle) -> URL? {
        guard hasCustomUI == true,
              let resourcesURL = bundle.resourceURL else { return nil }
        let uiDir = resourcesURL.appendingPathComponent("ui", isDirectory: true)
        let entry = ui?.resolvedEntryHTML ?? "index.html"
        let entryURL = uiDir.appendingPathComponent(entry)
        return FileManager.default.fileExists(atPath: entryURL.path) ? entryURL : nil
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
