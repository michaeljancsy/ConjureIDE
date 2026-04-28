# Vector telemetry slots (length = max_frames)

## Context

Telemetry today is the read-back twin of params: scripts publish DSP
state to the UI via up to 8 named `f32` slots (this plan bumps to 16
— see "TELEMETRY_LEN bump" below), snapshotted per render block,
shipped at display-link rate (~30–120 Hz) inside `audio.onFrame`'s
`telemetry` field. Author API:

- Rust: `ctx.set_telemetry(SLOT, value)` (`Context` method in
  `rust/conjuredsp-rs/src/context.rs`)
- Python: `telemetry["slot_key"] = value`

That covers meters (envelope, GR, sidechain RMS) but not curves —
which there are real use cases for:

- A non-linear filter's actual frequency response across the block
- A compressor's gain-trajectory plot (per-sample GR)
- A pre-clipping waveform for a distortion's "this is what the script
  is about to clip" debug view
- A NAM model's per-sample activation magnitude

This plan extends telemetry with **vector slots** — one `f32` per audio
frame in the current render block. Allocation tracks
`maximumFramesToRender` (declared once at `allocateRenderResources`,
re-allocated only when the host changes max-frames), so the hot path
never allocates. Two phases:

1. JSON transport, plain arrays. Lands the API + use cases.
2. (Conditional) base64 + `Float32Array` fast path, only if Phase 1
   measurements show the JSON encoder cost matters.

External use cases like FFT bins / oscilloscope traces are already
served by `audio.onFrame`'s opt-in `fft: true` path and raw RMS/peak;
vector telemetry is specifically for **script-computed** curves.

**No back-compat constraint.** Telemetry is unreleased, so we're free
to pick the API that reads best rather than the one that minimizes
churn.

## TELEMETRY_LEN bump: 8 → 16

While we're touching the metadata schema, raise the slot ceiling:

- Vector slots count against the same limit, so an 8-band compressor
  with a couple of meters already crowds 8.
- The cost is trivial: `[AtomicU32; 8]` (32 bytes static) becomes
  `[AtomicU32; 16]` (64 bytes static) in the kernel — same scaling
  rule as `PARAM_COUNT = 16`.
- Updates needed in three places (already kept in sync):
  - `rust/conjure_dsp/src/params.rs:13` — `pub const TELEMETRY_LEN: usize = 16`
  - `rust/conjuredsp-rs/src/context.rs:4` — same
  - `rust/include/conjure_dsp.h:20` — `#define TELEMETRY_LEN 16`

## Zero-cost-when-unused discipline

A core invariant: a script that declares no vector telemetry pays zero
allocation and zero per-block cost for the vector machinery. Concretely:

- The 16-slot scalar ring (`[AtomicU32; 16]`, 64 bytes) is allocated
  unconditionally (matches today's pattern at the bumped count).
  Vector slot buffers are allocated **only for slots whose metadata
  declares `shape: "vector"`**.
- Per declared vector slot: ~16 KB worst case at `max_frames=2048`
  (8 KB script-side numpy/WASM static + 8 KB host-side AtomicU32
  ring + a 4-byte seq counter). At `max_frames=4096`, ~32 KB.
- A script declaring no vector slots allocates 0 bytes for vectors
  on the host side. WASM scripts pay their `static mut [f32;
  MAX_FRAMES]` allocation only for declared vector slots; the
  `telemetry!` macro only emits the static when `vector_telemetry()`
  is used.
- `Backend::read_telemetry_vec` defaults to a no-op; the kernel never
  calls it for slots whose metadata says `shape: "scalar"`.
- The display-link tick still does its single FFI call to fetch
  metadata + early-return-on-empty (unchanged from today).

## Design summary

**Author API.**

Method names are explicit about shape — no overloading, no ambiguity
at the call site. With no back-compat constraint, `set_telemetry`
becomes `set_telemetry_scalar` for symmetry with the new
`set_telemetry_vector`.

```rust
// Rust:
telemetry! {
    GR_DB     = scalar_telemetry().unit("dB"),   // scalar
    ENV_CURVE = vector_telemetry(),              // vector — length = max_frames
}

// Inside process(), inside ctx scope:
ctx.set_telemetry_scalar(GR_DB, gr_db);
ctx.set_telemetry_vector(ENV_CURVE, &env_curve);  // slice up to max_frames
```
```python
# Python — pre-seeded by the host so writes are dict updates,
# never key insertions or allocations:
TELEMETRY = {
    "gr_db":     {"unit": "dB"},                 # scalar (default shape)
    "env_curve": {"shape": "vector"},            # vector
}
def process(inputs, outputs, frame_count, sample_rate, params, transport, telemetry):
    telemetry["gr_db"] = gr_db
    np.copyto(telemetry["env_curve"], env_curve)  # in-place, no alloc
```

**UI consumer — single polymorphic namespace.**
```js
audio.onFrame(frame => {
  const gr    = frame.telemetry["GR_DB"];       // number (scalar slot)
  const curve = frame.telemetry["ENV_CURVE"];   // Array<number>, length ≤ max_frames
                                                // (Phase 2: Float32Array)
});
```

The slot's declared shape determines the value's type. Authors know
which slot is which from the preset they're writing — no separate
`telemetry_shapes` side-channel.

**Allocation lifecycle.**

- Slot metadata declared once at script load (`telemetry!` macro,
  `TELEMETRY` dict). Adds `shape: "scalar" | "vector"` field on
  `TelemetryMetadata` (defaults to `"scalar"`).
- Vector slot buffers are allocated in the kernel at
  `dsp_kernel_allocate_render_resources(max_frames)` — the existing
  hook that already sizes the numpy I/O arrays. Each declared vector
  slot gets its own `Vec<AtomicU32>` of length `max_frames` plus an
  `AtomicU32` seq counter; un-declared slots allocate nothing.
- Hot path: writer memcpys (Rust slice copy / numpy in-place write)
  into the slot's buffer + bumps the per-slot seq counter.
  **Zero allocation per block.**
- If the host re-prepares the AU with a new `max_frames`, vector
  buffers are dropped + re-allocated outside the audio thread (same
  guarantee as today's numpy I/O buffers, which already track
  max_frames via the same hook).

**Lock-free read at display-link cadence — seqlock per slot.**

A 2048-element vector can't be atomic; we need a primitive that lets
the audio thread write atomically *as a unit* and the UI thread either
read a coherent snapshot or retry. Options considered:

| Primitive | Memory | Audio-thread cost | UI starvation |
|---|---|---|---|
| Seqlock | 1× buffer + 1 atomic seq | memcpy + 2 atomic stores | bounded — audio writes once per block (~ms) |
| Triple buffer | 3× buffer + 1 atomic ptr | memcpy + 1 atomic store | wait-free always |

**Recommendation: seqlock.** 1/3 the memory (up to 16 slots ×
`max_frames` × 4 bytes per host-side ring vs 3× that for triple
buffer), simpler
implementation, and the audio thread's write cadence (one memcpy per
render block, ~5–50 ms apart) means the reader can starve at most for
the duration of one memcpy — an order of magnitude shorter than the
display-link tick. Triple-buffer's wait-free property doesn't buy us
anything we can perceive.

**Pattern:** writer increments seq before write, increments again
after; reader reads seq → memcpy → reads seq, retries if either copy
saw a write-in-progress (odd seq) or seq changed mid-read.

## Phase 1 — JSON transport

### Files

| File | What changes |
|------|-------------|
| `rust/conjure_dsp/src/params.rs` | `TelemetryMetadata` gains `shape: String` (`"scalar"` default, `"vector"`) |
| `rust/conjure_dsp/src/kernel.rs` | Per-vector-slot `Vec<AtomicU32>` + `AtomicU32` seq counter; allocate in `allocate_render_resources(max_frames)`; new `read_telemetry_vec(slot, out)` API |
| `rust/conjure_dsp/src/backend.rs` | New trait method `read_telemetry_vec(&self, slot, &mut out) -> usize` with a `0`-returning default impl. Kernel calls this once per declared vector slot post-process, then runs the seq-bracketed copy into the AtomicU32 ring. **All concurrency lives here, once.** |
| `rust/conjure_dsp/src/python_backend.rs` | At telemetry-dict pre-seed time, vector-shaped slots get a `np.zeros(max_frames, f32)` instead of a scalar `0.0`. `read_telemetry_vec` impl: pull the numpy array's `data_ptr()`, copy `out.len()` floats into `out`. |
| `rust/conjure_dsp/src/wasm_backend.rs` | `read_telemetry_vec` impl: call `get_telemetry_vec_ptr(slot)` WASM export, copy `out.len()` floats from WASM linear memory at that offset into `out`. Mirrors the existing `get_input_ptr` / `get_output_ptr` ingestion shape. |
| `rust/conjure_dsp/src/lib.rs` | New FFI: `dsp_kernel_read_telemetry_vec(kernel, slot_idx, out_ptr, out_cap) -> u32` (returns elements written, 0 if slot is scalar or out of bounds) |
| `rust/conjuredsp-rs/src/lib.rs` | `telemetry!` macro accepts both `scalar_telemetry()` and `vector_telemetry()` builders; emits `shape: "scalar" \| "vector"` in metadata JSON. For vector slots, emits one `static mut [f32; MAX_FRAMES]` per slot plus a single `get_telemetry_vec_ptr(slot: i32) -> i32` export with a match statement over the vector slot indices. Out-of-range or scalar-typed slot indices return 0 (null) — host's `read_telemetry_vec` treats null as "skip this slot." Defines `pub const MAX_FRAMES: usize = 4096` (sized to cover Logic/Ableton/Reaper/Pro Tools incl. HDX), re-exported at crate root so authors can `use conjuredsp::MAX_FRAMES;`. |
| `rust/conjuredsp-rs/src/context.rs` | Renames existing `set_telemetry` → `set_telemetry_scalar`; adds new `set_telemetry_vector(slot, &[f32])` method. Bounds-checked (out-of-range slot = silent no-op, matches scalar precedent), null-pointer-safe, copies `min(slice.len(), MAX_FRAMES)` elements. Slices longer than `MAX_FRAMES` are silently truncated; rustdoc documents this and suggests a `debug_assert!` if the author wants loud failure. |
| `rust/conjuredsp-rs/src/params.rs` | New `scalar_telemetry()` + `vector_telemetry()` const-fn builders; existing `telemetry()` removed (no callers — telemetry is unreleased) |
| `rust/include/conjure_dsp.h` | Re-generated by cbindgen — adds `dsp_kernel_read_telemetry_vec` |
| `ConjureDSPExtension/Audio/AudioCaptureManager.swift` | `readTelemetry(kernel:)` branches on metadata `shape`; vector slots fill into a pre-allocated `[Float]` reused across ticks; payload becomes `[String: TelemetryValue]` where `TelemetryValue = .scalar(Float) \| .vector([Float])` |
| `ConjureDSPExtension/Common/DSPDocumentation.swift` | Author docs + a worked example: vector telemetry driving a hand-rolled `<canvas>` (the ergonomic `<cdp-scope>` wrapper is deferred — see "Deferred to follow-up" below) |

### Hot-path correctness — symmetric two-buffer design

Every backend runs scripts in isolated memory (Python heap, WASM
linear memory). Scripts never touch the host's AtomicU32 ring
directly — they write into their own private buffer first, and the
audio thread harvests post-`process()` into the kernel's ring with a
single seqlock implementation. **Same architecture for every
language.**

The only language-specific detail is "where does the script's buffer
live and how does the backend hand the host a pointer to it":

| | Python | WASM (Rust scripts) |
|---|---|---|
| Script-side buffer ("A") | `np.zeros(max_frames, f32)`, pre-seeded into the `telemetry` dict at load time | `static mut [f32; MAX_FRAMES]` per vector slot, declared by the `telemetry!` macro, lives in WASM linear memory |
| Script writes via | `np.copyto(telemetry["x"], curve)` | `ctx.set_telemetry_vector(SLOT, &slice)` |
| Backend exposes pointer to host via | numpy array's `data_ptr()` | `get_telemetry_vec_ptr(slot)` WASM export (mirrors existing `get_input_ptr` / `get_output_ptr` pattern) |
| Memcpy A→B impl | one-liner in `PythonBackend::read_telemetry_vec` | one-liner in `WasmBackend::read_telemetry_vec` |

The Backend trait gains exactly one method, with a no-op default so
backends without vector telemetry are unaffected:

```rust
trait Backend {
    // ... existing methods (process, params, scalar telemetry, …)
    fn read_telemetry_vec(&self, slot: usize, out: &mut [f32]) -> usize {
        0  // default: no vector telemetry. `out` left untouched.
    }
}
```

**Per-block valid length.** The harvest always copies exactly
`frame_count` (the current block size), not the length the script
wrote. Authors are expected to publish "one f32 per audio frame in
this block" — the natural use case. Rationale: keeps the API
mental model trivial (no per-slot "valid len" atomic, no Python
ergonomics question of "what does `np.copyto` do when shapes differ"),
and the realistic use case is `len == frame_count` by definition.
Authors writing fewer elements: the tail is stale (last block's
data) but never read, since the UI scrolls forward block-by-block.

Per-block sequence on the audio thread, after `process()` returns:

```text
for each declared vector slot s:
    seq[s].fetch_add(1, Release)       // mark write-in-progress (odd)
    backend.read_telemetry_vec(s, &mut scratch[..frame_count])
    copy scratch[..frame_count] into ring[s][..frame_count] using AtomicU32::store(Relaxed)
    seq[s].fetch_add(1, Release)       // mark complete (even)
```

UI reader (display-link tick), per slot:

```text
loop:
    s1 = seq[slot].load(Acquire)
    if s1 & 1 != 0: continue           // mid-write, retry
    for i in 0..n: scratch[i] = ring[slot][i].load(Relaxed)
    s2 = seq[slot].load(Acquire)
    if s1 != s2: continue               // changed during read, retry
    break
```

**Why this design wins on parity:**

- One seqlock implementation in `kernel.rs`, called identically for
  every backend. No language-specific concurrency code.
- Python's plain-`f32` numpy view never aliases the host's atomic ring
  — script-side and host-side memory are physically separate.
- WASM's natural shape (script writes its own linear memory, host
  reads via export pointer) becomes the canonical shape; Python
  conforms to it. A future native-Rust backend (or any other
  language we add) drops in the same way: implement one trait method.
- Per-block cost: one memcpy A→B per declared vector slot, ~2 µs at
  max_frames=2048, on the audio thread. Negligible. Per-slot memory
  cost: ~16 KB worst case (8 KB script-side + 8 KB host ring).
- Backends that don't have vector telemetry pay zero — the default
  trait impl returns 0 and the kernel's "for each declared vector
  slot" loop is empty when nothing's declared.

### Deferred to follow-up: `<cdp-scope>` + `manifest.telemetry`

The ergonomic `<cdp-scope>` web component, the `manifest.telemetry`
schema block, the matching `BundleUIValidator` rule, and the
`.claude/preview/scope.html` preview page are deferred to a follow-up
task: [`<cdp-scope>` oscilloscope component for vector
telemetry](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214322161753392)
(Asana `1214322161753392`).

Phase 1 of vector telemetry ships the kernel + backend + FFI + author
API only. Authors who want a visualization in Phase 1 hand-roll a
`<canvas>` against `audio.onFrame` (the worked example in
`DSPDocumentation.swift` shows how). When the follow-up lands, the
common case becomes one `<cdp-scope telemetry="…">` tag.

The full original `<cdp-scope>` design — kept here so the follow-up
task has a starting point — follows.

#### `<cdp-scope>` design (deferred)

Narrow design space (1D curve over frame_count), so we can pick
sensible defaults without first watching presets ship handrolled
versions.

**Author-facing API:**

```html
<cdp-scope telemetry="env_curve"
           length="512"               <!-- optional; default = full vector -->
           min="-1" max="1"           <!-- optional; default = auto-range -->
           draw="line"                 <!-- line | filled | dots -->
           grid                        <!-- optional gridlines -->
></cdp-scope>
```

**Why `draw=` and not `style=`?** Browsers parse the `style` HTML
attribute as inline CSS at the platform level — `style="line"` would
silently resolve to "no rules" without ever reaching our component.
`draw` avoids the collision.

**Behavior:**

- Internal `<canvas>` sized to the host element via `ResizeObserver`.
- Subscribes to `audio.onFrame`, redraws on each frame whose
  `frame.telemetry[name]` is a vector.
- **`length` attribute:** when present, draws the first `N` elements
  of the vector (where `N = length`). When absent, draws all
  `frame_count` elements. v1 keeps it simple — no scrolling, no
  ring-buffer concatenation across frames; the value is "show me a
  prefix of this block's vector."
- **Decimation:** when (vector slice to draw).length > canvas.width
  × 2, draw one min+max pair per pixel column (fast waveform-draw
  technique). At smaller ratios, draw a polyline directly.
- **Auto-range:** when `min`/`max` attrs are absent, track
  independent min/max with ~1 s decay (so GR-in-dB which is always
  ≤ 0 doesn't waste half the canvas, and env curves around 0 still
  look balanced); fixed when both attrs are set.
- **Theme** via CSS variables, all defaulting to existing cdp-ui
  tokens:
  - `--cdp-scope-line-color` (default `--cdp-accent`)
  - `--cdp-scope-fill-color` (default `--cdp-accent` at 0.2 alpha)
  - `--cdp-scope-grid-color` (default `--cdp-grid` if present, else
    transparent)
- Loose name resolution: same case/underscore/space-insensitive
  rules as `<cdp-slider param="…">`, so `telemetry="env_curve"`
  matches a slot declared as `EnvCurve` or `env_curve` from either
  language.
- BundleUIValidator extension: warn when `<cdp-scope telemetry="x">`
  references a slot not in `manifest.telemetry`. (See manifest.json
  schema change below.)

**Out of scope for v1:** dual-channel/stereo overlay, frequency-domain
mode (use `audio.onFrame`'s built-in FFT instead), per-frame
annotation markers, scrolling/oscilloscope-trigger modes. Ship narrow,
iterate based on real preset usage.

### Manifest schema change (deferred)

Also deferred to the `<cdp-scope>` follow-up
([`1214322161753392`](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214322161753392)),
since the static validator rule it enables is what makes it
load-bearing. The shape, kept here as the starting point for the
follow-up:

`manifest.json` (schemaVersion 2) gains an optional `telemetry`
block, mirroring the existing `manifest.params` shape so the static
validator can lint `<cdp-scope telemetry="…">` references the same
way it lints `<cdp-slider param="…">`:

```jsonc
{
  "schemaVersion": 2,
  "params": [ /* ... */ ],
  "telemetry": [
    {"key": "gr_db",     "name": "GR_DB",     "shape": "scalar", "unit": "dB"},
    {"key": "env_curve", "name": "ENV_CURVE", "shape": "vector"}
  ],
  "ui": { /* ... */ }
}
```

- Optional. Bundles without a `telemetry` block fall back to
  runtime resolution via `smoke_test_ui` (component binds — or
  doesn't — based on the actually-loaded script's metadata).
- Same loose-name-matching rules as params.
- BundleUIValidator's `<cdp-scope telemetry="x">` check: if
  `manifest.telemetry` exists, warn on unresolved references with
  Levenshtein "did you mean" suggestions, matching the existing
  param-name validator behavior.

### Verification

- **Rust unit tests** (`conjuredsp-rs/src/context.rs`): mirror the
  existing `set_telemetry_*` tests for the vector path — bounds,
  null-buf, partial-fill, last-write-wins.
- **Rust unit tests** (`conjure_dsp/src/kernel.rs`): seqlock
  correctness — torn-read detection, retry until consistent, scalar
  + vector slot interleaving.
- **`ConjureDSPLogicTests`**: extend `AudioCaptureManager` tests with
  a vector-slot fixture; assert payload shape (array vs scalar) and
  that scalar consumers don't break.
- **Manual end-to-end**: build a Python preset publishing
  `env_curve` of length `frame_count`, drive a hand-rolled
  `<canvas>` subscribing to `audio.onFrame`, eyeball that the trace
  tracks audio reasonably. Repeat with a Rust/WASM preset to verify
  both backend paths.

## Phase 2 — Conditional binary fast path

**Only execute Phase 2 if real-world Phase 1 use feels sluggish.**
Trigger conditions, in priority order:

1. Manual feel — using a Phase 1 vector-telemetry preset in a DAW
   feels laggy or stutters where it shouldn't.
2. Wall-clock profiling later points at `JSONEncoder` in the
   `audio.onFrame` path as the dominant cost when something else
   triggers a perf investigation.

No quantitative threshold up front; premature optimization. Phase 1
ships first, sits in the wild, and we revisit only if there's a real
signal.

If we do cross the trigger, the cheapest swap-in:

- Vector slot wire format becomes
  `{"__type":"f32","b64":"<base64>"}` instead of a JSON array.
- `customui-bridge.js` auto-decodes that envelope into a
  `Float32Array` before invoking `audio.onFrame` callbacks. The
  author-facing API is unchanged: `frame.telemetry["env_curve"]` is
  *either* `Array<number>` (Phase 1) *or* `Float32Array` (Phase 2);
  any code that treats it as a typed-array-like (length + index)
  works for both.
- ~10× cheaper on both sides of the bridge (no decimal-string format,
  no `JSON.parse` of N floats); ~50% less wire bytes than JSON.

The author API (`frame.telemetry["x"]` returning either a `number`,
`Array<number>`, or `Float32Array`) doesn't change — Phase 2 is a
drop-in transport swap. Code that uses index/length on the value
works for both `Array<number>` and `Float32Array` shapes.

Files touched in Phase 2:
- `ConjureDSPExtension/Audio/AudioCaptureManager.swift` — base64
  encode the vector buffer instead of building a JSON array.
- `ConjureDSPExtension/Resources/customui-bridge.js` — auto-decode
  the envelope on the receive side.

## Verification across both phases

- `xcodebuild ... -only-testing:ConjureDSPLogicTests` (~6s)
- `cd rust && cargo test -- --test-threads=1` (Python tests share
  interpreter)
- Manual scope-style preset, both Python and Rust variants, both
  factory-buffer-size = 64 and =2048 ranges, hot-reload across UI
  edits.

## Critical files at a glance

| File | Phase |
|------|------|
| `rust/conjure_dsp/src/params.rs` | 1 |
| `rust/conjure_dsp/src/kernel.rs` | 1 |
| `rust/conjure_dsp/src/python_backend.rs` | 1 |
| `rust/conjure_dsp/src/wasm_backend.rs` | 1 |
| `rust/conjure_dsp/src/lib.rs` | 1 |
| `rust/conjuredsp-rs/src/lib.rs` | 1 |
| `rust/conjuredsp-rs/src/context.rs` | 1 |
| `rust/conjuredsp-rs/src/params.rs` | 1 |
| `rust/include/conjure_dsp.h` | 1 (regenerated) |
| `ConjureDSPExtension/Audio/AudioCaptureManager.swift` | 1, 2 |
| `ConjureDSPExtension/Common/DSPDocumentation.swift` | 1 |
| `ConjureDSPExtension/Resources/customui-bridge.js` | 2 |

Deferred to the [`<cdp-scope>` follow-up](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214322161753392):
| File | Notes |
|------|-------|
| `ConjureDSPExtension/Resources/cdp-ui.js` | `<cdp-scope>` web component |
| `ConjureDSPExtension/Model/PresetManifest.swift` | optional `manifest.telemetry` block |
| `ConjureDSPExtension/Model/BundleUIValidator.swift` | `<cdp-scope telemetry="…">` reference rule |
| `.claude/preview/scope.html` | synthetic-data preview page |

## Asana

Single ticket: "Vector telemetry slots (length = max_frames)" in the
ConjureDSP Backlog (project gid `1214126484601018`), Post-Launch
section. The ticket links back to this plan; status updates land in
Asana per the project convention.
