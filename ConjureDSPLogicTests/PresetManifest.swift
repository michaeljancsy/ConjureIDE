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

    /// Sibling note that appears alphabetically just above `params` in
    /// the pretty-printed JSON. Test-target mirror of the field on the
    /// extension's `PresetManifest`; needed here so save-rewrite tests
    /// can pin that the kernel-derived note is cleared alongside the
    /// `params` cache it documents.
    var paramsNote: String? = nil

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

    /// Telemetry slot declarations. Test-target mirror of the field on
    /// the extension's `PresetManifest`; needed here so save-rewrite
    /// tests can pin that the kernel-derived telemetry cache is cleared
    /// alongside `params` (third member of PR #298's bug family).
    var telemetry: [TelemetryDecl]?

    /// Telemetry slot declaration — mirrors the documented slot name a
    /// DSP script publishes via `ctx.set_telemetry_*` (Rust) or the
    /// `TELEMETRY` dict (Python).
    struct TelemetryDecl: Codable, Equatable {
        var name: String
        var key: String?
        /// `"scalar"` (default) or `"vector"`.
        var shape: String?
        /// Display unit (e.g. `"dB"`).
        var unit: String?
    }

    /// Optional free-form author metadata.
    var meta: Meta?

    /// Map `paramsNote` to the on-disk key `_paramsNote`. Mirrors the
    /// CodingKeys override on the extension's `PresetManifest` so the
    /// test target encodes/decodes manifests bit-identical to runtime.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case entry
        case language
        case ui
        case params
        case paramsNote = "_paramsNote"
        case telemetry
        case meta
    }

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

    /// Test-target mirror of `defaultScaffoldUI` on the extension. See
    /// the extension's docstring for the rationale.
    static let defaultScaffoldUI = UI(
        entryHTML: "ui/index.html",
        width: 520,
        height: 380,
        fps: 30,
        audioFrames: false
    )

    /// Test-target mirror of `scaffoldUI(withOverrides:)`. Keep in sync
    /// with the extension definition — `SavePresetScaffoldRewriteTests`
    /// pins the override merge behavior.
    static func scaffoldUI(withOverrides overrides: UI?) -> UI {
        var ui = defaultScaffoldUI
        guard let overrides else { return ui }
        if let v = overrides.entryHTML { ui.entryHTML = v }
        if let v = overrides.width { ui.width = v }
        if let v = overrides.height { ui.height = v }
        if let v = overrides.fps { ui.fps = v }
        if let v = overrides.audioFrames { ui.audioFrames = v }
        if overrides.audioFrames == true && overrides.fps == nil {
            ui.fps = 60
        }
        return ui
    }

    /// Test-target mirror of `applyingSaveRewrites(scaffoldUI:)` on the
    /// extension's `PresetManifest`. See the extension's docstring for
    /// the failure-mode rationale (Failures #1 / #2 / #4 in the
    /// 2026-05-08 /try-it sweep, plus the telemetry follow-on). Both
    /// copies must stay in sync — the `SavePresetScaffoldRewriteTests`
    /// + `SavePresetTelemetryRewriteTests` suites pin the contract.
    func applyingSaveRewrites(
        scaffoldUI: Bool,
        scaffoldUIOverrides: UI? = nil
    ) -> PresetManifest {
        var copy = self
        copy.params = nil
        copy.paramsNote = nil
        copy.telemetry = nil
        if scaffoldUI, copy.ui == nil {
            copy.ui = Self.scaffoldUI(withOverrides: scaffoldUIOverrides)
        }
        return copy
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
    /// root. Returns nil when the write is safe to land, or an error
    /// message when it would leave the bundle in an unloadable state.
    enum ValidationAudience {
        case agent
        case human
    }

    static func validateProposedWrite(
        content: String,
        bundleRoot: URL,
        audience: ValidationAudience = .agent,
        fileManager: FileManager = .default
    ) -> String? {
        guard let data = content.data(using: .utf8) else {
            return "Manifest content is not valid UTF-8."
        }
        let parsed: PresetManifest
        do {
            parsed = try decode(from: data)
        } catch {
            let detail = describeDecodingError(error)
            switch audience {
            case .agent:
                return "Manifest write rejected: content does not parse as a valid manifest. Keep the existing fields (schemaVersion, entry, language, ui) and only add/modify the params block. \(detail)"
            case .human:
                return "manifest.json doesn\u{2019}t parse: \(detail)"
            }
        }
        let entryURL = bundleRoot.appendingPathComponent(parsed.entry)
        if !fileManager.fileExists(atPath: entryURL.path) {
            switch audience {
            case .agent:
                return "Manifest write rejected: `entry` points at \"\(parsed.entry)\" but that file doesn't exist in the bundle. Either restore the original `entry` value or write the entry file first."
            case .human:
                return "manifest.json: `entry` points at \"\(parsed.entry)\" but that file doesn\u{2019}t exist in the bundle yet."
            }
        }
        return nil
    }

    private static func describeDecodingError(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        func pathString(_ path: [CodingKey]) -> String {
            let parts = path.map { $0.stringValue }
            return parts.isEmpty ? "<root>" : parts.joined(separator: ".")
        }
        switch decodingError {
        case .keyNotFound(let key, let ctx):
            return "missing required field `\(key.stringValue)` at \(pathString(ctx.codingPath))."
        case .typeMismatch(_, let ctx):
            return "wrong type at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
        case .valueNotFound(_, let ctx):
            return "expected a value at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
        case .dataCorrupted(let ctx):
            return "invalid JSON at \(pathString(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
