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
                unit: d.unit,
                curve: d.curve,
                style: d.style,
                options: d.options
            )
        }
    }
}
