# RFC: Sparse / event-list telemetry shape

**Status:** Draft (design only — no implementation in this PR).
**Author:** Claude Code session, 2026-05-08.
**Surfaced by:** Slice-n-Dice /try-it sweep on 2026-05-08, runs 09 + 10
(granular freeze experiments). Asana ticket
[1214648868510486](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214648868510486).
**Related prior art:** `.claude/plans/vector-telemetry.md` (the
existing scalar/vector design).

---

## 1. Problem statement

Telemetry today has two shapes: **scalar** (one `f32` per render
block, ~150 bytes for the whole `audio.onFrame` payload) and **vector**
(one `f32` per audio frame in the current block, length =
`frame_count`, sized at allocation to `MAX_FRAMES = 4096`). Vector is
the right shape for *continuous* per-sample curves: an envelope
trajectory, a per-sample GR plot, an oscilloscope view of a non-linear
filter's instantaneous output. It is the wrong shape for **sparse
events** — single-sample triggers that occur at a much lower rate than
the audio sample rate.

The granular freeze case from runs 09 + 10 is the canonical example.
At 48 kHz with a target grain density of ~10 Hz, a 512-frame render
block contains on average ~0.1 grain triggers. The author wants the UI
to receive the within-block frame index of each trigger plus a value
(grain pitch, normalized read position, amplitude — anything useful
for visualization). Today they have to encode this as a vector slot:

- Allocate one `f32` per frame.
- Write `0.0` to every frame *except* the trigger frames.
- Write the trigger value at the trigger frames.
- Hope the consumer can distinguish "no event" (`0.0`) from "event with
  value `0.0`."

Run 09 hit exactly that ambiguity. The author was publishing
`norm_pos` (grain read position, range `0.0..1.0`) at trigger frames.
A grain that legitimately started at the very front of the buffer
produces `norm_pos ≈ 0.0`, which is indistinguishable from "no event."
The fix in run 09 was a sentinel hack: clamp the published value to
`max(0.005, norm_pos)`, accepting the precision loss to keep the
trigger detectable. Run 10 carried the same clamp forward. Neither
the API nor the docs have anywhere to put a "this is a sparse event
channel" annotation, so every author hits this independently.

The bandwidth waste compounds the ergonomic problem. ~99.9% of a
512-sample vector at 10 Hz density is zeros; at 4096-sample blocks
under Pro Tools HDX it's ~99.99% zeros. With 16 vector slots all
publishing sparse events, the JSON-encoded `audio.onFrame` payload
crosses 64 KB / tick at 30 Hz — the same payload that JS-side
`<cdp-scope>` then has to walk to draw five non-zero pixels.

We want a third shape — **events** — that publishes a list of
`(frame_index, value)` pairs per render block, with a clear
"no-event" semantic (the list is just empty), no sentinel-value
precision loss, and a wire payload sized to the event count rather
than the frame count.

---

## 2. Proposed API surface

End-to-end, layer by layer. The macro-shape twin of the existing
`scalar_telemetry()` / `vector_telemetry()` constructors plus a new
`events_telemetry()`.

### 2.1 Author API — Rust

A new constructor in `rust/conjuredsp-rs/src/params.rs` and a new
macro-emitted method on `Context` (analogous to
`set_telemetry_vector` from `vector-telemetry.md`):

```rust
use conjuredsp::*;
setup!();

params! {
    DENSITY = freq().min(0.5).max(40.0).default(10.0).unit("Hz"),
}

telemetry! {
    GRAIN_EVENTS = events_telemetry(),               // unitless
    GRAIN_PITCH  = events_telemetry().unit("st"),    // semitones
}

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channel_count: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
    let mut grain_events: heapless::Vec<(u32, f32), 64> = heapless::Vec::new();
    // ... DSP loop, on each trigger:
    //   let _ = grain_events.push((frame_idx as u32, norm_pos));

    ctx.set_telemetry_events(GRAIN_EVENTS, &grain_events);
}
```

Exact signature on the macro-emitted `__CdpTelemetryEventExt` trait:

```rust
fn set_telemetry_events(
    &self,
    slot: usize,
    events: &[(u32, f32)],
);
```

Tradeoffs / specifics:

- `(u32, f32)` not `(usize, f32)` — wire-stable across host/guest, and
  4 bytes per index leaves headroom for `MAX_FRAMES` growth far past
  4096 without ever stretching the payload.
- Slice argument, not iterator — keeps the audio-thread call path
  alloc-free. Authors stage events into a stack-resident buffer
  (`heapless::Vec` or a fixed-size `[(u32, f32); N]` + cursor) and
  pass a `&[(u32, f32)]` once at the bottom of `process()`.
- The macro silently no-ops when called on a slot whose declared
  shape isn't `events` (matches the precedent set by
  `set_telemetry_scalar` / `set_telemetry_vector` for the
  out-of-range and shape-mismatch cases).
- Cap: drop events past `MAX_EVENTS_PER_BLOCK` (proposed `64`, see
  open question O3). Drop is silent — same precedent as today's
  out-of-range parameter index.

### 2.2 Author API — Python

Mirror the Rust shape exactly. `TELEMETRY` declaration adds
`"shape": "events"`; the script writes a list of pairs (or a
2-column numpy array) into `ctx.telemetry[key]`:

```python
TELEMETRY = {
    "grain_events": {"shape": "events"},
    "grain_pitch":  {"shape": "events", "unit": "st"},
}

def process(ctx):
    events = []  # list[tuple[int, float]]
    # ... DSP loop, on each trigger:
    #   events.append((frame_idx, norm_pos))
    ctx.telemetry["grain_events"] = events
```

The Python backend (`rust/conjure_dsp/src/python_backend.rs`) accepts
either:
- `list[tuple[int, float]]` — natural Python idiom, used in examples.
- `numpy.ndarray` of shape `(N, 2)` with dtype `float32` — the host
  reinterprets column 0 as frame index. Authors who staged events in
  a preallocated numpy buffer for cache locality can hand it through
  with no list conversion.

The pre-seeded `ctx.telemetry["grain_events"]` slot contains an empty
list at the top of every block; assigning a fresh list (the natural
Python idiom) is fine — the snapshot path drains it once and that
allocation lifetime is bounded to the block. (Open question O7 —
whether to pre-seed a reusable bytearray-backed buffer for authors
who want zero per-block alloc.)

### 2.3 Wire format — Rust → Swift

A new FFI export on the kernel mirroring `dsp_kernel_read_telemetry_vec`:

```c
// Returns the number of (u32 index, f32 value) pairs written to `out`.
// `out_len` is the capacity of `out` in *pairs*, not bytes.
size_t dsp_kernel_read_telemetry_events(
    const dsp_kernel_t* kernel,
    size_t slot_index,
    uint32_t* out_indices,
    float*    out_values,
    size_t    out_len_pairs
);
```

Two parallel arrays (`u32[]` indices + `f32[]` values), not an array
of structs, because:
- Swift sees them naturally as `[UInt32]` + `[Float]` without
  defining a C struct or worrying about Swift's struct-layout rules.
- Lets the host-side ring use independent `AtomicU32` arrays — the
  same pattern as `vec_telemetry`, just half the data per slot per
  block.

Backend trait gains:

```rust
fn read_telemetry_events(
    &self,
    slot_index: usize,
    out_indices: &mut [u32],
    out_values: &mut [f32],
) -> usize;
```

Default impl returns `0` (matches the `read_telemetry_vec` precedent
where backends without vector slots are no-ops).

### 2.4 Wire format — Swift → JS

Add a third case to `TelemetryValue` in `AudioCaptureManager.swift`:

```swift
enum TelemetryValue {
    case scalar(Float)
    case vector([Float])
    case events([Event])    // new

    struct Event {
        let frame: UInt32
        let value: Float
    }
}
```

`CustomUIWebView.forwardAudioFrame` serializes the events case as an
array of plain objects:

```json
{
  "telemetry": {
    "GRAIN_EVENTS": [
      {"frame": 12,  "value": 0.000},
      {"frame": 184, "value": 0.421},
      {"frame": 391, "value": 0.823}
    ]
  }
}
```

Object-of-pairs (rather than a single flat `[12, 0.0, 184, 0.421,
…]`) because:
- Self-documenting at the consumer site (`evt.frame`, `evt.value`).
- Object-creation cost in V8 is negligible at <64 events / tick;
  the JSON encoder cost is dominated by the float-formatting, not
  the key strings (the encoder hits the same number of digits
  regardless of wrapping).
- Forward-compatible: extra event fields (e.g. `channel`, `id`)
  can be added without breaking consumers that read only `frame` +
  `value`.

Payload size at the worst-case 64 events × ~32 bytes / event = ~2 KB
per slot per tick. At 30 Hz × 16 slots that's a ~960 KB/s ceiling
— well under the ~480 KB/s a single vector slot at `MAX_FRAMES =
4096` already produces.

### 2.5 JS consumer side — `customui-bridge.js`

Zero changes. The bridge already passes `frame.telemetry` through
opaquely (see `customui-bridge.js:1546` — `frame.telemetry[key]`). The
events list arrives as a JS `Array<{frame, value}>` and the consumer
treats it the same way they'd treat any other typed slot value.

### 2.6 cdp-ui.js component changes

Two touch points in `ConjureDSPExtension/Resources/cdp-ui.js`:

1. **`<cdp-scope>` (vector-only today, line 1697):** stays vector-only.
   Documenting "events slots are not drawn by `<cdp-scope>`" in the
   `telemetry=` attribute help text avoids the silent-empty-canvas
   trap when an author swaps a slot's shape mid-iteration.
2. **New `<cdp-events>` component:** sized to the same surface as
   `<cdp-scope>` — `telemetry=`, `length=`, `min=`, `max=`, `draw=`
   attributes — but renders each event as a vertical tick (or a short
   colored bar) at its `frame / frame_count` X position. `draw=`
   options: `tick` (default, single pixel column at `value`-mapped
   Y), `bar` (full-height bar, `value` controls opacity),
   `dots` (circle at the X/Y point). History is desirable
   (default: 1 second of accumulated events, age-faded) — events are
   the kind of channel where a snapshot of "the last grain trigger"
   conveys nothing and a scrolling history is the actual asked-for
   visualization.

Authors who want a non-component view of events (e.g. flashing an LED
on the most recent trigger, or counting events into a state value)
can read `frame.telemetry["GRAIN_EVENTS"]` directly inside their
`audio.onFrame` handler. Same access pattern as scalar/vector.

---

## 3. Use cases

### 3.1 Grain triggers (the canonical case)

```rust
telemetry! {
    GRAIN_TRIGGER = events_telemetry(),    // value = norm_pos in [0, 1]
}

// In the grain scheduler:
if grain_due {
    let _ = events.push((frame_idx as u32, norm_pos));
    spawn_grain(...);
}
ctx.set_telemetry_events(GRAIN_TRIGGER, &events);
```

UI consumer:

```html
<cdp-events telemetry="GRAIN_TRIGGER" min="0" max="1" draw="tick"></cdp-events>
```

Replaces the run-09/run-10 sentinel hack outright. `norm_pos = 0.0`
is now an unambiguous "grain at the front of the buffer," not "no
grain this tick."

### 3.2 Transient detector hits

```python
TELEMETRY = {
    "transient": {"shape": "events", "unit": "dB"},
}

def process(ctx):
    hits = []
    for i in range(ctx.frame_count):
        x = ctx.inputs[0][i]
        if detector.step(x):
            hits.append((i, detector.last_db))
    ctx.telemetry["transient"] = hits
```

UI: `<cdp-events telemetry="transient" min="-60" max="0">` with
event opacity scaled by dB — visualizes attack density over time
without the author having to author a custom canvas.

### 3.3 Step-sequencer events

A 16-step beat sequencer publishes a step trigger when the playhead
crosses a step boundary. Step index lives in `value`, frame index is
the within-block timing.

```rust
telemetry! {
    STEP_FIRED = events_telemetry(),    // value = step_index as f32
}

// In the sequencer's process loop:
let new_step = (sample_pos / samples_per_step) as u32;
if new_step != current_step {
    let frame_in_block = (new_step as i64 * samples_per_step
        - block_start_sample) as u32;
    let _ = events.push((frame_in_block, new_step as f32));
    current_step = new_step;
}
ctx.set_telemetry_events(STEP_FIRED, &events);
```

UI lights up the active step pad in real time, with sub-block
accuracy that wouldn't be possible from the per-block `transport`
update channel alone.

### 3.4 MIDI-like event passthrough

A script that converts a CV input into note events publishes
note-on events with pitch:

```python
TELEMETRY = {
    "note_on": {"shape": "events", "unit": "st"},
}

def process(ctx):
    notes = []
    for i in range(ctx.frame_count):
        cv = ctx.inputs[1][i]   # sidechain bus = CV
        if quantizer.step(cv):
            notes.append((i, quantizer.last_pitch_st))
    ctx.telemetry["note_on"] = notes
```

The UI keyboard widget can light up the matching key with sample-accurate
timing, even though MIDI itself is out of band for AUv3 effects (this
isn't a MIDI plug-in, it's an effect that *internally* derives note
timing from audio).

---

## 4. Comparison to existing shapes

A short decision tree for authors:

```
What is the rate of meaningful values your DSP wants to publish?

├─ One value per render block
│  └─> scalar_telemetry()
│      e.g. envelope-follower output, current GR, sidechain RMS
│
├─ One value per audio frame, every frame, every block
│  └─> vector_telemetry()
│      e.g. per-sample GR trajectory, instantaneous filter response,
│           pre-clipping waveform
│
├─ Sparse triggers — most frames have nothing to say
│  └─> events_telemetry()
│      e.g. grain triggers, transient detections, step boundaries,
│           note-on events
│
└─ Continuous-but-low-rate (e.g. one value every 32 frames)
   └─> Still vector_telemetry(), unless density drops below
       ~5% of frame_count, at which point events wins on bandwidth
       and ergonomics. See "When to reach for events vs vector"
       below.
```

**When to reach for events vs vector** (the boundary case):

- Events win on bandwidth once density falls below ~12% of
  `frame_count` — the per-event payload (one `u32` index + one
  `f32` value + JSON wrapping) is roughly 2× the per-frame payload
  in a vector slot, so the crossover is around the 12% mark.
- Events win on *correctness* whenever `0.0` is a legitimate value
  the consumer needs to distinguish from "no event."
- Events win on *intent legibility* whenever the value is
  semantically a discrete trigger, even if dense — e.g. a
  beat-grid visualizer where every sample is on a beat boundary
  *should* still be events, because the consumer wants
  `(frame, beat_index)` pairs, not `[beat_at_0, beat_at_1, ...]`.
- Vector wins anytime a `<cdp-scope>` rendering of the data is
  the right visualization — i.e. the data really is a continuous
  waveform-like curve.

### 4.1 Could "vector with sparse encoding" replace this?

Considered. A sparse vector encoding would publish
`(count, [frame_indices…], [values…])` over the existing vector
channel: same allocation, smaller wire payload, no new shape. It
costs less plumbing but loses on three fronts:

- **The `0.0` ambiguity isn't resolved.** A vector consumer still
  has to know it's "really" sparse to interpret `0.0` correctly,
  and the author still has to encode the "is-event" bit somewhere.
- **`<cdp-scope>` would draw it wrong.** Existing vector consumers
  treat the array as a per-sample curve; a sparse-encoded vector
  would render as a noisy mess with whatever junk leftover sits
  past the `count` prefix. We'd need a flag anyway.
- **The author API still needs `events` semantics.** Whatever shape
  we ship has to give authors a clean "publish this list of
  triggers" call site. Once we have that on the author side, the
  wire-format optimization is independently decidable, and the
  parallel-arrays format proposed here is already efficient enough.

Sparse-vector encoding is rejected in favor of a first-class shape.

### 4.2 Could "publish only the leading N values + a count" replace this?

Same family of solution. Same downsides. Plus it caps event count
arbitrarily low (you'd typically pick N=8 or N=16 to keep the wire
payload tight), where the proposed `MAX_EVENTS_PER_BLOCK = 64` is
chosen against actual densest-realistic-use targets.

---

## 5. Open questions

1. **O1 — Same-frame deduplication.** Do we deduplicate events that
   share the same `frame` index, or pass them through? Two grain
   triggers on the same sample is a real possibility (a Euclidean
   density at high settings). Proposed: pass through, keep
   declaration order. Authors who want one-per-frame can dedupe
   themselves.

2. **O2 — Ordering guarantee.** Does the host promise to deliver
   events in `frame` order, or in author-write order? Proposed: the
   host preserves author-write order verbatim. No sort. Authors who
   need frame-sorted output sort themselves; the host does not pay
   the cost on behalf of authors who don't care.

3. **O3 — `MAX_EVENTS_PER_BLOCK`.** What's the cap? Proposed: 64.
   At a worst-case 4096-frame block, that's one event per ~64 audio
   frames, well above any realistic event-density use case. Each
   event costs 8 bytes of host-side ring storage and ~32 bytes of
   wire payload. At 64 × 16 slots that's 8 KB host storage and
   ~32 KB wire payload at 30 Hz — within the same order as the
   existing vector budget.

4. **O4 — Drop policy on overflow.** When an author writes more
   than `MAX_EVENTS_PER_BLOCK` events, do we keep the first N or
   the last N? Proposed: keep the first N, log a warning on the
   first overflow per script load (rate-limited). First-N is the
   simpler implementation and matches the "earliest events most
   musically meaningful" intuition for trigger-based content.

5. **O5 — Optional value.** Is the `value` field optional? An author
   publishing pure timing events ("grain fired at frame 184, no
   metadata") has no useful value to publish. Proposed: not
   optional — `value` always exists, defaults to `0.0` when the
   author doesn't supply one. Keeps the wire format and FFI shape
   simple. The cost is negligible (4 bytes per event).

6. **O6 — Bounds checking on `frame`.** The host should clamp
   `frame >= frame_count` to be silently dropped (the event would
   refer to a sample that wasn't in this block). Should the kernel
   emit a script-error for out-of-range frame indices? Proposed:
   silent drop, log on the first occurrence per slot per script
   load (matches the rate-limited-warning pattern of O4).

7. **O7 — Pre-seeded reusable buffer (Python).** Should
   `ctx.telemetry["grain_events"]` be pre-seeded with a reusable
   numpy array of shape `(MAX_EVENTS_PER_BLOCK, 2)` plus a
   per-block `length` setter, the way vector telemetry is
   pre-seeded? Pro: zero per-block alloc for power authors. Con:
   the natural Python idiom for events is a list, and forcing
   numpy here makes the simple case harder. Proposed: accept both
   shapes (list or `(N, 2)` numpy), don't pre-seed. Authors who
   need zero-alloc reach for numpy themselves.

8. **O8 — Cross-block carryover.** If an author writes events with
   `frame >= frame_count` (e.g. a "pending" trigger they want
   delivered next block), does the host carry it forward, or drop?
   Proposed: drop (per O6). Cross-block scheduling is the script's
   responsibility — the script already knows next block's
   `frame_count` is unknown until next `process()` call.

9. **O9 — Metadata on the slot.** Does the slot's metadata need a
   value-range hint (`min`, `max`) the way params do? Today the
   `<cdp-scope>` component handles this with HTML attributes. The
   `<cdp-events>` component would do the same. Proposed: no slot
   metadata for value range; HTML attributes are sufficient.
   `unit` stays as today (used by `formatValue`).

10. **O10 — Event channel ID.** Should the event payload carry an
    `id` field for cross-block tracking (e.g. matching a `note_on`
    to its `note_off`)? Proposed: no in v1. Authors who need
    cross-block identity assign their own `id` and pack it into
    `value` (e.g. as a small integer), or use the bundle-private
    `STATE` channel for richer correlation. Add a third payload
    field if a real preset surfaces the gap.

---

## 6. Implementation cost estimate

Touched files, rough line-count, dependencies. No code in this RFC.

**Author-side macros + types** (~ +120 lines)
- `rust/conjuredsp-rs/src/params.rs` — `events_telemetry()`
  constructor, `TelemetryShape::Events` variant, JSON-serialize the
  new shape.
- `rust/conjuredsp-rs/src/lib.rs` — `telemetry!` macro emits a
  `static mut TELEMETRY_EVENT_BUFS: [(u32, f32); 64]` per events slot,
  plus `get_telemetry_events_indices_ptr(slot)` /
  `get_telemetry_events_values_ptr(slot)` /
  `get_telemetry_events_count(slot)` exports.
- New `__CdpTelemetryEventExt` trait with
  `set_telemetry_events(&self, slot, &[(u32, f32)])`.

**Backend trait** (~ +60 lines per backend)
- `rust/conjure_dsp/src/backend.rs` — add
  `read_telemetry_events(slot, out_indices, out_values) -> usize`
  with a no-op default.
- `rust/conjure_dsp/src/python_backend.rs` — mirror the existing
  vector path: each block, walk the post-process telemetry dict,
  parse list-of-tuples or `(N, 2)` numpy into the index/value
  staging buffers. Cap at `MAX_EVENTS_PER_BLOCK`.
- `rust/conjure_dsp/src/wasm_backend.rs` — add the new exports to
  the discovery sweep, mirror the existing `read_telemetry_vec`
  pure-memory-read pattern.

**Kernel storage + harvest** (~ +150 lines)
- `rust/conjure_dsp/src/kernel.rs` — new
  `EventsTelemetrySlots { rings: Vec<Option<EventRing>>, … }`
  alongside `vec_telemetry`. Each `EventRing` is two parallel
  `Vec<AtomicU32>`s (indices as `u32`, values as `f32::to_bits()`
  in a `u32` slot) sized to `MAX_EVENTS_PER_BLOCK`, plus a count
  atomic. Same seqlock writer protocol as vector telemetry.
- Harvest loop in `process_block` mirrors the existing vec harvest:
  `try_lock` the events guard, walk events slots, drain backend
  → ring.

**FFI** (~ +30 lines)
- `rust/conjure_dsp/src/lib.rs` (the kernel-side `lib.rs`) +
  `rust/include/conjure_dsp.h` —
  `dsp_kernel_read_telemetry_events(...)` returning the pair count.

**Swift** (~ +100 lines)
- `ConjureDSPExtension/Audio/AudioCaptureManager.swift` —
  `TelemetryValue.events([Event])` case, scratch buffers
  (`telemetryEventsIndices: [UInt32]`, `telemetryEventsValues:
  [Float]` sized to `MAX_EVENTS_PER_BLOCK * MAX_TELEMETRY_SLOTS`),
  per-slot read in `readTelemetry`.
- `ConjureDSPExtension/UI/CustomUIWebView.swift` — switch on the
  new case in `forwardAudioFrame`'s telemetry serialization
  (~10 lines).

**JS** (~ +200 lines)
- `ConjureDSPExtension/Resources/cdp-ui.js` — new `<cdp-events>`
  component (think `<cdp-scope>` but tick-rendered with history).
- `ConjureDSPExtension/Resources/customui-bridge.js` — zero
  changes needed; `frame.telemetry` is opaque-passthrough today.

**Tests** (~ +250 lines across the existing test targets)
- `rust/conjure_dsp/src/python_backend.rs` and `wasm_backend.rs`
  unit tests — extract metadata, write events, read back via
  backend.
- `rust/conjure_dsp/src/kernel.rs` integration tests — full
  publish/harvest round-trip including overflow + same-frame
  duplicates.
- `ConjureDSPLogicTests` — Swift-side TelemetryValue.events
  decoding round-trip via FFI.
- `ConjureDSPTests` — exported AU template carries events
  metadata + harvests events correctly (the template's
  `ExportAudioCaptureManager` mirrors `AudioCaptureManager` and
  needs the same case added).

**Documentation** (~ +80 lines)
- `ConjureDSPExtension/Common/DSPDocumentation.swift` — `telemetry`
  topic gains an "events" section.
- `docs/custom-ui-component-library.md` — `<cdp-events>` reference.
- This RFC moves to `docs/sparse-telemetry.md` (or merges into the
  existing `vector-telemetry.md` plan) once accepted.

**Total estimate:** ~900 lines across 12 files, ~3 days of
implementation work (sized similarly to the vector-telemetry plan,
which is the closest precedent). No new dependencies; the format
re-uses pyo3 list/numpy interop, wasmtime memory reads, JSON
serialization, and the seqlock pattern that vector telemetry already
established.

**Export AU template parity:** the export template carries its own
copy of `AudioCaptureManager` (`ExportAudioCaptureManager`) and the
`runtime-config.json` schema. Any change here has to be mirrored.
The existing `check-drift` skill catches this kind of divergence
post-hoc; this implementation should land both sides in the same PR
so drift never opens.
