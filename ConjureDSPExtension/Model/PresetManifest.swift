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

    /// Parameter declarations. Cache of the kernel-extracted metadata,
    /// refreshed on every save and on drift detection at load. Lets the
    /// AU parameter tree, stock sliders, and the custom-UI JS bridge's
    /// `_init` all build from these BEFORE the DSP script is compiled or
    /// loaded — custom UIs render immediately instead of waiting on
    /// rustc for a Rust preset, and the "first `_init` has stale
    /// previous-preset metadata" race that we otherwise paper over with
    /// UI-side loader hacks goes away.
    ///
    /// Authority lives in the script (`PARAMS` / `params!()`); this
    /// block is overwritten on every successful save and whenever a load
    /// detects drift between the manifest and the kernel. Hand-edits
    /// here will be lost on the next save — `_paramsNote` documents
    /// that contract in the file itself.
    ///
    /// Manifests without `params` keep the v1 behavior (metadata sourced
    /// from DSP extraction); the loader hacks above still apply in that
    /// path.
    var params: [ParamDecl]?

    /// Sibling note that appears alphabetically just above `params` in
    /// the pretty-printed JSON. Set to a fixed warning string by
    /// `PresetManager.syncManifestParamsFromKernel` on every non-empty
    /// write; cleared along with `params` on empty input. Underscore
    /// prefix marks it as machine-managed (JSON has no comment syntax).
    /// Default `nil` so existing memberwise-init call sites compile
    /// without passing it.
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

    /// Telemetry slot declarations. Optional — when present, lets the
    /// static `BundleUIValidator` lint `<cdp-scope telemetry="…">` /
    /// `<cdp-meter source="telemetry:…">` references against the names a
    /// preset is documented to publish, with "did you mean" suggestions
    /// on near-miss typos. When absent, telemetry-binding components
    /// fall back to runtime resolution: they bind whichever slot the
    /// loaded DSP script actually publishes under that name.
    var telemetry: [TelemetryDecl]?

    /// Telemetry slot declaration — mirrors the documented slot name a
    /// DSP script publishes via `ctx.set_telemetry_*` (Rust) or the
    /// `TELEMETRY` dict (Python). The duplication with the script is
    /// deliberate (same rationale as `ParamDecl`): manifest is
    /// authoritative for static validation, the script is authoritative
    /// for runtime values, and a post-load validator can warn on drift.
    struct TelemetryDecl: Codable, Equatable {
        var name: String
        var key: String?
        /// `"scalar"` (default — one float per render block) or
        /// `"vector"` (one float per audio frame in the block).
        var shape: String?
        /// Display unit (e.g. `"dB"`). Advisory; consumers like
        /// `<cdp-meter unit="db">` may pick a default when omitted.
        var unit: String?
    }

    /// Optional free-form author metadata.
    var meta: Meta?

    /// Map `paramsNote` to the on-disk key `_paramsNote`. The underscore
    /// is illegal in a Swift property name but is the conventional way to
    /// flag a machine-managed sibling field in JSON (closest equivalent
    /// to a comment). Listing every property is required when overriding
    /// CodingKeys — synthesized `Codable` won't fall back to defaults
    /// for unlisted fields.
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

    /// Audio-frame rate to use when the custom UI subscribes. The manifest
    /// value passes through with a sane floor and ceiling: minimum 1 Hz
    /// (avoid div-by-zero in the gate), maximum 120 Hz (caps IPC bandwidth
    /// at typical display-refresh ceilings; CADisplayLink won't fire faster
    /// than vsync regardless). Defaults to 30 when omitted.
    var resolvedFPS: Int {
        let raw = ui?.fps ?? 30
        return min(120, max(1, raw))
    }

    /// Whether the bundle opts into audio frame delivery.
    var audioFramesEnabled: Bool {
        ui?.audioFrames ?? false
    }

    /// Default `ui` block emitted by every scaffold path (fresh bundle
    /// creation in `PresetManager.savePreset` AND the existing-bundle
    /// branch when the caller upgrades to scaffold_ui=true). Centralized
    /// so the two sites stay in sync — drift between them is what
    /// produced the "ui block missing on re-save" failure mode in the
    /// 2026-05-08 /try-it sweep.
    ///
    /// `audioFrames` defaults to false to match the documented opt-in
    /// semantics (see `get_docs("ui")`): pure-control UIs are the
    /// common case and shouldn't pay for the audio capture pipeline.
    /// Authors who add a `<cdp-meter>` / `<cdp-scope>` / `<cdp-bargraph>`
    /// or call `audio.onFrame` get a `BundleUIValidator` failure
    /// (`audio_frames_not_enabled`) pointing at the manifest fix —
    /// no more silent flat-meter footgun.
    static let defaultScaffoldUI = UI(
        entryHTML: "ui/index.html",
        width: 520,
        height: 380,
        fps: 30,
        audioFrames: false
    )

    /// Apply optional per-field overrides on top of `defaultScaffoldUI`.
    /// Used by the MCP `save_preset` scaffold path so the agent can ship
    /// the user-requested dimensions (`ui_width` / `ui_height`) and
    /// frame-capture intent (`ui_audio_frames`) in the same call instead
    /// of save → write_bundle_file → save again. Per-field optionality
    /// means a caller passing just width keeps the default height/fps/
    /// audioFrames — no concrete value sneaks in from a half-specified
    /// override struct.
    static func scaffoldUI(withOverrides overrides: UI?) -> UI {
        var ui = defaultScaffoldUI
        guard let overrides else { return ui }
        if let v = overrides.entryHTML { ui.entryHTML = v }
        if let v = overrides.width { ui.width = v }
        if let v = overrides.height { ui.height = v }
        if let v = overrides.fps { ui.fps = v }
        if let v = overrides.audioFrames { ui.audioFrames = v }
        // Bump fps default to 60 when the scaffold opts into audio frames
        // and the caller didn't pin fps explicitly. Pure-control UIs keep
        // fps 30 (no global render-budget regression); audio-frame UIs
        // (scope / spectrum / meter) get the smoother default they
        // typically end up requesting by hand anyway. Caught by
        // 2026-05-13 /try-it sweep, Asana 1214786384716214.
        if overrides.audioFrames == true && overrides.fps == nil {
            ui.fps = 60
        }
        return ui
    }

    /// Pure rewrite applied to an existing manifest before re-saving a
    /// user bundle's entry script. Owns three invariants the
    /// `bundleExists` branch of `PresetManager.savePreset` previously
    /// got wrong:
    ///
    /// 1. **`params`/`_paramsNote` are cleared.** They're a kernel-
    ///    derived cache — the new `source` may declare entirely
    ///    different params (or none), and the next compile-and-sync
    ///    will repopulate accurately. Preserving the stale block let
    ///    the MCP `save_preset` handler's `applyManifestParams` pin
    ///    the old metadata, which then made the manifest-priority
    ///    guard in `readParamNames` skip the kernel's freshly-
    ///    extracted metadata, which made `syncManifestParamsFromKernel`
    ///    write the OLD params straight back to disk. (Failure #2 in
    ///    the 2026-05-08 /try-it sweep — `Sidechain Ducker` re-saved
    ///    in Rust kept Python's threshold/ratio defaults.)
    ///
    /// 2. **A `ui` block is added when `scaffoldUI && self.ui == nil`.**
    ///    The previous behavior dropped a starter `ui/index.html` on
    ///    disk but left the manifest unchanged, producing an orphan
    ///    that `BundleUIValidator` flagged on the next write — the
    ///    agent had to hand-author the `ui` block. (Failures #1 / #4
    ///    in the same sweep.)
    ///
    /// 3. **`telemetry` is cleared.** Same root cause family as
    ///    `params`: telemetry is a kernel-derived cache of slots the
    ///    script publishes via `ctx.set_telemetry_*` (Rust) or the
    ///    `TELEMETRY` dict (Python). A re-save may flip the language
    ///    or drop / rename slots, and the next `syncManifestTelemetryFromKernel`
    ///    repopulates accurately. Preserving the stale block leaves
    ///    `BundleUIValidator` linting `<cdp-meter source="telemetry:…">`
    ///    against slot names the new script no longer publishes —
    ///    third member of the bug family PR #298 fixed.
    ///
    /// Returns a copy. Caller decides whether the rewrite materially
    /// differs from the input and skips the disk write when not.
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

    /// Audience the validator's error messages target. The MCP path is
    /// driven by an agent that benefits from explicit guidance about
    /// which fields to preserve; the in-app Monaco editor is driven by
    /// a human who's already looking at the file and just needs the
    /// concrete failure.
    enum ValidationAudience {
        case agent
        case human
    }

    /// Preflight a proposed `manifest.json` write for the given bundle
    /// root. Returns nil when the write is safe to land, or an error
    /// message when it would leave the bundle in an unloadable state.
    ///
    /// Two rejection conditions:
    ///
    /// 1. **Content doesn't decode as a valid manifest.** Missing or
    ///    wrong-typed fields, trailing commas, etc. `PresetBundle.load`
    ///    would return nil after the refresh, silently invalidating
    ///    `currentBundle`.
    /// 2. **`entry` points at a missing file.** Decode succeeds but
    ///    the referenced entry script doesn't exist in the bundle.
    ///
    /// Pure function: doesn't touch disk except to check that
    /// `entry`'s file exists under `bundleRoot`.
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

    /// Pull a useful one-liner out of a `DecodingError`. The default
    /// `localizedDescription` is famously vague ("The data couldn\u{2019}t
    /// be read because it isn\u{2019}t in the correct format") — the
    /// associated values have the actual signal (which key was missing,
    /// what type was expected, where the corruption is). Falls back to
    /// the localized description for non-DecodingError cases (shouldn't
    /// happen for JSON, but belt-and-suspenders).
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
            let location = pathString(ctx.codingPath)
            return "missing required field `\(key.stringValue)` at \(location)."
        case .typeMismatch(_, let ctx):
            let location = pathString(ctx.codingPath)
            return "wrong type at \(location): \(ctx.debugDescription)"
        case .valueNotFound(_, let ctx):
            let location = pathString(ctx.codingPath)
            return "expected a value at \(location): \(ctx.debugDescription)"
        case .dataCorrupted(let ctx):
            let location = pathString(ctx.codingPath)
            return "invalid JSON at \(location): \(ctx.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
