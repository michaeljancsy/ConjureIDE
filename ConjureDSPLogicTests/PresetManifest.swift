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
    static let currentSchemaVersion = 2

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

    /// Parameter declarations. When present, this is the authoritative
    /// source of metadata: the AU parameter tree, stock sliders, and the
    /// custom-UI JS bridge's `_init` all build from these BEFORE the DSP
    /// script is compiled or loaded. That lets custom UIs render
    /// immediately instead of waiting on rustc for a Rust preset, and
    /// eliminates the "first `_init` has stale previous-preset metadata"
    /// race that we otherwise paper over with UI-side loader hacks.
    ///
    /// A post-DSP-load validator warns when the DSP's own param
    /// declarations drift from this list. Manifests without `params` keep
    /// the v1 behavior (metadata sourced from DSP extraction); the loader
    /// hacks above still apply in that path.
    var params: [ParamDecl]?

    /// Parameter declaration — mirrors
    /// `ConjureDSPExtensionAudioUnit.ParamMetadata` intentionally. The
    /// duplication keeps the manifest schema decoupled from the AU type
    /// (so someone renaming the Swift field doesn't silently break
    /// on-disk manifests) and gives the manifest a place to hold fields
    /// the AU doesn't care about (e.g., future `data:` hint payloads).
    struct ParamDecl: Codable, Equatable {
        var name: String
        var key: String?
        var min: Float
        var max: Float
        var `default`: Float
        /// Display unit (e.g. `"Hz"`, `"dB"`). Optional — toggles, choices,
        /// and percentage-style controls often have no meaningful unit. A
        /// missing or empty value reads as `""` downstream.
        var unit: String?
        /// "linear" (default) or "log" (geometric).
        var curve: String?
        /// "slider" (default), "toggle", "choice", "integer".
        var style: String?
        /// Label array for "choice" params.
        var options: [String]?
    }

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

    /// Preflight a proposed `manifest.json` write for the given bundle
    /// root. Returns nil when the write is safe to land, or a
    /// human-readable error message when it would leave the bundle in
    /// an unloadable state.
    ///
    /// Two rejection conditions:
    ///
    /// 1. **Content doesn't decode as a valid manifest.** Missing or
    ///    wrong-typed fields, trailing commas, etc. `PresetBundle.load`
    ///    would return nil after the refresh, silently invalidating
    ///    `currentBundle` — the agent would see `get_bundle_info`
    ///    return `bundle: null` and perceive a "preset dropped" state.
    /// 2. **`entry` points at a missing file.** Decode succeeds but
    ///    the referenced entry script doesn't exist in the bundle
    ///    (e.g. agent swapped `process.rs` for `process.py` without
    ///    creating the Python file). Same silent-unload outcome.
    ///
    /// Pure function: doesn't touch disk except to check that
    /// `entry`'s file exists under `bundleRoot`. Exposed on
    /// PresetManifest so tests can exercise it without spinning up an
    /// AU or MCP handler.
    static func validateProposedWrite(
        content: String,
        bundleRoot: URL,
        fileManager: FileManager = .default
    ) -> String? {
        guard let data = content.data(using: .utf8) else {
            return "Manifest content is not valid UTF-8."
        }
        let parsed: PresetManifest
        do {
            parsed = try decode(from: data)
        } catch {
            return "Manifest write rejected: content does not parse as a valid manifest. Keep the existing fields (schemaVersion, entry, language, ui) and only add/modify the params block. Underlying error: \(error.localizedDescription)"
        }
        let entryURL = bundleRoot.appendingPathComponent(parsed.entry)
        if !fileManager.fileExists(atPath: entryURL.path) {
            return "Manifest write rejected: `entry` points at \"\(parsed.entry)\" but that file doesn't exist in the bundle. Either restore the original `entry` value or write the entry file first."
        }
        return nil
    }
}
