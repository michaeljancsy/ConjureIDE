# Preset manifest schema versioning

Every `.cdp` preset bundle carries a `manifest.json` with a top-level
`schemaVersion` integer. This doc covers what each version means, why
both exist, the bulk migration of factory presets to v2 (commit
`df964fc`), and why v1 reading is intentionally kept around.

## Versions at a glance

| | v1 | v2 |
|---|---|---|
| Field declared | `"schemaVersion": 1` | `"schemaVersion": 2` |
| `params` block in manifest | absent | required (array of `{name, min, max, default, unit, curve?, style?, options?}`) |
| AU param tree populated | **after** DSP script compiles, by reading kernel-side metadata | **before** DSP script compiles, from the manifest |
| Custom UI on first paint | placeholder defaults until kernel finishes (multi-second on Rust) | correct defaults immediately |
| Static lint of `<cdp-slider param="…">` | impossible — manifest doesn't list params | resolves against `manifest.params` with Levenshtein "did you mean" |

The tradeoff is exactly the one v2 was added to fix: **a custom UI
should not render against placeholder values during a slow Rust
compile.** v1 bundles that don't ship a custom UI work fine on either
schema; v2 is strictly better for any bundle that does.

## Concrete shapes

### v1

```json
{
  "schemaVersion": 1,
  "entry": "process.py",
  "language": "python"
}
```

Param metadata is declared inside the DSP script (Python `PARAMS = {…}`
or Rust `params! { … }`). The kernel exposes that metadata via
`dsp_kernel_param_metadata_json` after `dsp_kernel_load_script` /
`dsp_kernel_load_wasm` finishes. The AU host calls `readParamNames()`
post-load and rebuilds the param tree from what the kernel reports.

### v2

```json
{
  "schemaVersion": 2,
  "entry": "process.py",
  "language": "python",
  "params": [
    { "name": "cutoff",    "min": 20.0,  "max": 20000.0, "default": 1000.0, "unit": "Hz", "curve": "log" },
    { "name": "resonance", "min": 0.5,   "max": 10.0,    "default": 1.0,    "unit": "Q" }
  ],
  "ui": {
    "entryHTML": "ui/index.html",
    "width": 600,
    "height": 440,
    "fps": 30,
    "audioFrames": true
  }
}
```

The manifest's `params` array is the **source of truth at bundle-load
time** — the AU populates the param tree before the DSP script even
starts compiling. The kernel's metadata still gets read after the
script loads, and is used as a sanity check + as the authoritative
source for the *next* `compile_and_run` if the new script declares a
different shape (see commit `8fd89bc` — `compile_and_run` rebuilds the
param tree on metadata change).

The `params[*]` shape mirrors `ConjureDSPExtensionAudioUnit.ParamMetadata`
but the duplication is intentional: the manifest schema stays
decoupled from the runtime Swift type so a Swift-side rename can't
silently invalidate on-disk manifests.

`unit` is non-optional in the Codable shape — emit `"unit": ""` for
unitless params.

## Where v1 lives in the code

After the bulk factory migration, the surface area kept around for
v1 reading is small:

| Location | Purpose |
|----------|---------|
| `PresetManifest.swift:14` — `static let currentSchemaVersion = 2` | New bundles created via `PresetBundle.create` get v2 |
| `PresetManifest.swift:16` — `var schemaVersion: Int = Self.currentSchemaVersion` | Decoder treats missing/old version as default |
| `PresetManifest.swift:43` — `var params: [ParamDecl]?` | Optional, so v1 manifests with no `params` array decode fine |
| `BundleUIValidator.swift:198–213` — `checkSchemaV2Recommended` | Warning when a v1 bundle ships a custom UI |
| `ConjureDSPExtensionAudioUnit.swift` — `readParamNames()` post-load fallback | Populates the AU param tree from kernel metadata when manifest had no `params` |

That last one is **not strictly v1-only code** — v2 bundles also
go through `readParamNames()` after script load as a sanity check,
and `compile_and_run` reuses it to detect when the script's actual
metadata diverges from the manifest. So it stays regardless.

## The bulk migration (commit `df964fc`)

As of April 2026 the repo had 91 v1 factory bundles alongside 13
already-v2 ones. Fragmentation that every fresh agent and contributor
had to learn ("v2 means custom UIs; v1 is grandfathered, do I need to
upgrade?").

Migration: an ad-hoc Python script parsed each entry script
(`process.py` via `ast`, `process.rs` via regex on the `params!`
macro), resolved the builder calls (`freq` / `db` / `time_ms` /
`pct` / `mix` / `toggle` / `ratio` / `choice` / `integer` / `param`)
against the same defaults `conjuredsp.params` and `conjuredsp-rs/params.rs`
use at runtime, and wrote v2 manifests with a `params` array.

Verified by `ConjureDSPTests/FactoryPresetValidationTests` (every
factory preset loads, none trips a validator fail) and
`PresetManifestSchemaV2Tests` (Codable round-trip + Python-vs-Rust
sibling agreement). Spot-checked against the 6 already-v2 bundles
(compressor / svf / wavefolder + their Rust siblings) — the parser
output was semantically identical (modulo two pre-existing
source-vs-manifest unit drifts, fixed in commit `4f88bdf`).

## Decision: keep v1 reading

After the migration, dropping the v1 fallback would simplify the
manifest layer (one validator rule + one `?` on a Codable field could
go). We chose not to. Reasoning:

1. **User data compat.** User bundles in
   `<AppGroup>/Presets/` from older builds may still be on v1.
   Forcing v2-only reading would silently make those bundles
   disappear from the preset browser. Even with ~3 active users,
   that's data loss in the user's eyes.
2. **The lazy-migration rule (`feedback_no_one_shot_migration_tools`).**
   The standing instruction is "migrate lazily on read, produce new
   format on every write." `PresetBundle.create` already emits v2,
   so any save / Save As of an old bundle rewrites it as v2
   naturally. Eventually all user bundles will be v2 without us
   touching their data.
3. **The cost of keeping v1 reading is ~zero.** Three lines of
   Codable defaults plus a validator warning rule. The validator
   rule still has value for hand-written or agent-generated v1
   bundles.

The investigation is filed as Asana
`1214285271028886` (now complete with this decision documented as a
comment).

## When would we drop v1?

Genuinely viable triggers:

- We add a v3 with a fundamentally different shape (e.g. nested param
  groups, or a typed-enum schema-version field) and need to keep the
  decoder readable. Dropping v1 at the same time as adding v3 would
  collapse two transitions into one.
- A user-facing performance issue from the post-load `readParamNames()`
  path that we want to skip entirely for known-v2 bundles.
- A security or correctness issue specifically in v1 metadata
  extraction.

None of these is on the horizon. v1 reading should stay until at
least one of them lands.

## Author guidance (in-plugin)

The author-facing docs at `get_docs("ui")` already say:

> Always prefer v2 + `params` over relying on DSP-extracted metadata.

That's right. Authors writing new presets should never use v1.
v1 is a compatibility-only path.

## Future v3?

If a v3 ever happens, the obvious shapes are:

- **Nested param groups** for multi-band processors (e.g. `params[*].group`
  + UI grouping hints).
- **Vector telemetry slots** (see Asana `1214284776999532`) might
  need a `manifest.telemetry` block; that's currently planned as an
  additive change to v2, not a new schema version.
- **Polyphony / voice management** if we ever ship instrument-style
  presets.

Each would need its own design doc + a clean migration story from v2
that respects the same lazy-migration discipline.
