import Foundation

/// `manifest.json` schema for a ConjureDSP preset bundle.
///
/// A preset bundle is a directory containing at minimum `manifest.json` and the
/// DSP entry script named by `entry`. Optional `ui/` assets let the preset ship
/// a custom HTML/JS interface that replaces the default parameter sliders.
///
/// Legacy single-file `.py` / `.rs` presets have no manifest and keep working
/// exactly as before — bundles are strictly opt-in.
struct PresetManifest: Codable, Equatable {
    /// Schema version. Increment when the wire format changes in a
    /// non-backward-compatible way.
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion

    /// Relative path (from the bundle root) to the DSP entry script.
    /// Typically `process.py` or `process.rs`.
    var entry: String

    /// Optional explicit language override. If omitted, derived from `entry`'s
    /// file extension (`.py` → python, `.rs` → rust).
    var language: String?

    /// Optional custom-UI configuration. When present and `ui/index.html` (or
    /// the path given by `entryHTML`) exists, the plugin renders this in place
    /// of `ParameterSlidersView`.
    var ui: UI?

    /// Optional free-form author metadata.
    var meta: Meta?

    struct UI: Codable, Equatable {
        /// Relative path (from the bundle root) to the HTML entry point.
        /// Defaults to `ui/index.html` when omitted.
        var entryHTML: String?

        /// Preferred width in points. Advisory; the host may clip or scale.
        var width: Int?

        /// Preferred height in points.
        var height: Int?

        /// Audio-frame delivery rate in Hz. Clamped to 15 or 30 in v1.
        /// Defaults to 30 when omitted (and `audioFrames == true`).
        var fps: Int?

        /// When true, the custom UI may subscribe to audio analysis frames
        /// (RMS / FFT / waveform) via the JS bridge. When false/omitted,
        /// audio frame delivery is disabled even if the UI tries to subscribe.
        var audioFrames: Bool?
    }

    struct Meta: Codable, Equatable {
        var author: String?
        var description: String?
        var category: String?
    }
}

// MARK: - Convenience

extension PresetManifest {
    /// Resolve the language implied by this manifest, preferring an explicit
    /// `language` field, falling back to the entry-script extension.
    var resolvedLanguage: ScriptLanguage {
        if let lang = language?.lowercased() {
            if lang == "rust" { return .rust }
            if lang == "python" { return .python }
        }
        let ext = (entry as NSString).pathExtension.lowercased()
        return ext == "rs" ? .rust : .python
    }

    /// Relative path to the HTML entry within the bundle, including the
    /// `ui/index.html` default.
    var uiEntryHTMLPath: String {
        ui?.entryHTML ?? "ui/index.html"
    }

    /// Audio-frame rate to use when the custom UI subscribes. Clamped to
    /// 15 or 30.
    var resolvedFPS: Int {
        switch ui?.fps ?? 30 {
        case ..<23: return 15
        default: return 30
        }
    }

    /// Whether the bundle opts into audio frame delivery.
    var audioFramesEnabled: Bool {
        ui?.audioFrames ?? false
    }
}

// MARK: - Encoding / Decoding helpers

extension PresetManifest {
    /// The canonical filename used inside a preset bundle directory.
    static let filename = "manifest.json"

    /// Decode a manifest from raw JSON data.
    static func decode(from data: Data) throws -> PresetManifest {
        let decoder = JSONDecoder()
        return try decoder.decode(PresetManifest.self, from: data)
    }

    /// Encode to pretty-printed JSON data suitable for writing to disk.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
