import Foundation

/// Bridge between the manifest's portable `ParamDecl` and the AU's
/// runtime `ParamMetadata`. Lives in a separate file so the test target
/// (which has its own copy of `PresetManifest.swift` without the AU) can
/// link cleanly.
extension PresetManifest {
    /// Convert manifest `params` declarations into the AU's
    /// `ParamMetadata`. Returns nil when the manifest has no `params`
    /// block (v1 bundles) — callers fall back to the v1 path where the
    /// kernel extracts metadata from the DSP source post-compile.
    func resolvedParamMetadata() -> [ConjureDSPExtensionAudioUnit.ParamMetadata]? {
        guard let decls = params, !decls.isEmpty else { return nil }
        return decls.map { d in
            ConjureDSPExtensionAudioUnit.ParamMetadata(
                name: d.name,
                key: d.key,
                min: d.min,
                max: d.max,
                default: d.default,
                unit: d.unit ?? "",
                curve: d.curve,
                style: d.style,
                options: d.options
            )
        }
    }
}

extension PresetManifest.ParamDecl {
    /// Reverse of `resolvedParamMetadata()`: convert kernel-extracted
    /// runtime metadata back into the on-disk manifest declaration form.
    /// Used by `save_preset` to mirror a freshly compiled script's
    /// `PARAMS` / `params!{}` block into `manifest.json`'s `params` array
    /// — closing the gap that previously forced authors of custom UIs to
    /// hand-write a v2 manifest after every scaffold.
    ///
    /// Empty `unit` strings round-trip to nil so the JSON stays compact
    /// (the manifest schema treats nil and "" as equivalent downstream).
    init(from m: ConjureDSPExtensionAudioUnit.ParamMetadata) {
        self.init(
            name: m.name,
            key: m.key,
            min: m.min,
            max: m.max,
            default: m.default,
            unit: m.unit.isEmpty ? nil : m.unit,
            curve: m.curve,
            style: m.style,
            options: m.options
        )
    }
}
