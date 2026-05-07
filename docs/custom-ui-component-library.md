# cdp-ui.js — Custom UI component library

Ships alongside `customui-bridge.js` in every preset bundle's rendering
pipeline. Injected into the WKWebView at `document-start` (after the
`window.ConjureDSP` bridge) so every custom UI has the components
available without asking.

Source: [`ConjureDSPExtension/Resources/cdp-ui.js`](../ConjureDSPExtension/Resources/cdp-ui.js)

## Goals that shaped it

- **No framework, no build step.** Authors open `ui/index.html` in
  Monaco and save — hot reload fires in ~300ms. No tooling, no
  dependencies, no bundler. Vanilla web components + one `<script>`
  tag.
- **Honest OS theming.** All styling keyed off CSS system colors
  (`CanvasText`, `Canvas`) so the UI tracks the host's light/dark mode
  without the author writing a theme switcher.
- **Param metadata as source of truth.** Authors reference params by
  name (`param="cutoff"`) and the components read min/max/default/curve/
  unit/style from the manifest — the same metadata the slider panel
  uses. No duplicated config.
- **Shadow DOM isolation.** Component internals don't leak, and
  page-level CSS can't accidentally mangle a slider's track. Authors
  customize via explicit CSS custom properties and `::part()` hooks.

## Components

| Tag | What it is |
|---|---|
| `<cdp-slider param="cutoff">` | Horizontal slider. Handles `curve:"log"` and `curve:"linear"` metadata automatically. Renders `label \| track \| value` row. |
| `<cdp-toggle param="bypass_eq">` | Switch for `style:"toggle"` params. |
| `<cdp-choice param="mode">` | Dropdown for `style:"choice"` params with the manifest-declared `options`. |
| `<cdp-xy param-x="cutoff" param-y="resonance" invert-y>` | Two-axis pad with a puck. Writes both params on drag. `invert-y` flips semantics so low Y = bottom (standard graph orientation). |
| `<cdp-knob param="threshold">` | Circular knob with vertical drag, mouse-wheel, keyboard nav, and double-click-to-default. Stacked layout (face / label / value). Default visual is themable via `--cdp-*` and `::part()`; for fully custom geometry, slot in your own SVG and consume the `--cdp-knob-norm` CSS variable. |
| `<cdp-meter source="peak-out">` | Read-only level meter with PPM ballistics (IEC 60268-18 default of 11.76 dB/s decay), peak-hold marker (~2 s, click-to-reset), and three-zone color gradient (green / yellow at `warn` / red at `clip`). Sources: `peak-in`, `peak-out`, `rms-in`, `rms-out`, or `telemetry:<key>`. Vertical or horizontal. Add `invert` to flip fill direction + color order for GR / "more is worse" sources. `gradient="smooth"` blends colors instead of hard-stopping at thresholds. Override `--cdp-meter-gradient` with any `linear-gradient(...)` for full custom palettes. No `param=` — meters are passive displays, not parameter controls. |
| `<cdp-scope telemetry="env_curve">` | Read-only oscilloscope that draws a vector telemetry slot as a waveform. `draw="line" \| "filled" \| "dots"`. `min`/`max` pin the y-range; omit either or both for auto-range with ~1 s decay. `length` clips the slice to the first N samples. Add `grid` for a reference grid. Long vectors decimate to one min+max pair per pixel column automatically. Theme via `--cdp-scope-line-color`, `--cdp-scope-fill-color`, `--cdp-scope-grid-color`. Same `audioFrames: true` gate as the meter. |
| `<cdp-panel>` | Thin layout wrapper — styled container with consistent padding/border. |

## Author-facing JS API (`window.ConjureDSP.ui`)

Exposed for preset JS that wants to go beyond the components:

- `control(index)` — handle to a single param:
  `{ get(), set(v), metadata, onChange(cb) }`. `onChange(cb)` fires
  whenever the parameter's value changes, regardless of source — your
  own `set()` calls, DAW automation, MIDI learn, MCP writes, preset
  load. Treat it as the single source of truth for visual updates so a
  hand-rolled widget redraws on the user's drag the same way it does
  on automation. (Self-writes are deduped on equal values, so a
  handler that re-sets the same value it received terminates after one
  hop.)
- `formatValue(value, meta)` — unit-aware formatter
  (`1000` → `"1.00 kHz"`, `5` → `"5.00 dB"`, etc.).
- `denormalize(t, meta)` / `normalize(v, meta)` — curve-aware mapping
  between the 0–1 AU slider space and the author's actual-value space.
- `parseUserValue(raw, meta)` — inverse of `formatValue`. Parses a
  user-typed string (`"1.5kHz"`, `"-3 dB"`, `"50%"`) back to a
  numeric value, honoring the same SI-prefix rollovers the formatter
  produces and clamping to `meta.min`/`meta.max`. Returns `null` on
  unparseable input. Used internally by the click-to-edit value
  text on `cdp-slider` / `cdp-knob`; exposed for authored UIs that
  render their own value displays.
- `requireVersion(n)` — future-proofing; asserts the library is at
  least version `n`.

## Bundle-private state channel — `ConjureDSP.state.*`

For UI-writable, audio-readable structured data that doesn't fit on
the AU parameter tree — sequencer steps, slot selections, NAM model
paths, MIDI-learn maps, captured impulse responses. State persists
in the **DAW project** (via `fullState` / `fullStateForDocument`),
not the bundle. New instances boot from the script's defaults; user
edits diverge into per-instance state; reopening the project
restores those edits.

The script declares defaults at module level (Python `STATE = {…}`)
or via `state_struct! { … } state!(State);` (Rust). The audio thread
reads through `ctx.state` (a read-only mapping); writes only happen
through this JS surface or the MCP `set_state` tool.

```js
ConjureDSP.state.get(key)               // current value
ConjureDSP.state.set(key, value)        // returns boolean —
                                         //   false on size cap reject
ConjureDSP.state.onChange(key, cb)      // fires on every set AND
                                         //   external _stateUpdate
                                         //   (DAW load / MCP / preset switch)
ConjureDSP.state.onAnyChange((k, v) => {})  // any-key fan-out;
                                              //   (k=null, v=null) = full reset
ConjureDSP.state.reset(key)             // restore one key to script default
ConjureDSP.state.resetAll()             // restore everything
```

**Behavioral notes:**

- `set` returns `false` when the resulting JSON would exceed
  `MAX_STATE_BYTES` (64 KiB default; presets can opt up to 1 MiB
  via `state!(State, max_bytes = N)` in Rust). Existing buffer is
  unchanged on rejection. Handle the boolean — silent drops are
  the worst-of-both-worlds.
- `onChange` fires synchronously inside `set`, so a widget that
  redraws in `state.onChange('slots', refreshGrid)` will see the
  user's drag the same way it sees a DAW load. No dedupe-on-equal
  for state — deep-equal on arrays/objects would dominate the cost;
  the author is responsible for not re-setting identical values
  every animation frame.
- Values must be JSON-serializable. The bridge serializes at the
  moment of `set` to size-check — later mutations to the same
  object reference are NOT visible to the kernel. Pass a fresh
  object/array on every change.
- Writing an undeclared key (one not in the script's `STATE` /
  `state_struct!`) succeeds at the kernel level but emits a
  one-time-per-key console warning so the author can spot the
  typo. The validator catches these statically too.

```html
<!-- A 32-step sequencer grid driven entirely by state. -->
<script>
  ConjureDSP.ready(() => {
    const cells = document.querySelectorAll('.cell');
    const refresh = (slots) => {
      cells.forEach((c, i) => c.classList.toggle('on', !!slots[i]));
    };
    refresh(ConjureDSP.state.get('slots') || []);
    ConjureDSP.state.onChange('slots', refresh);
    cells.forEach((c, i) => c.addEventListener('click', () => {
      const slots = (ConjureDSP.state.get('slots') || []).slice();
      slots[i] = slots[i] ? 0 : 1;
      const ok = ConjureDSP.state.set('slots', slots);
      if (!ok) console.warn('state cap exceeded — drop the write');
    }));
  });
</script>
```

## DSP→UI telemetry channel

For meters / visualizers that need to display **internal DSP state** —
gain reduction, envelope follower output, sidechain RMS, NAM model
magnitude — the `audio.onFrame` payload carries an optional
`telemetry` field populated from a per-block snapshot the DSP
publishes via [`Context::set_telemetry`](../rust/conjuredsp-rs/src/context.rs)
(Rust) or the `TELEMETRY` dict (Python).

This is the right answer for any "show me the value the DSP is
actually computing" use case. Don't mirror the DSP math in JS:
parameter changes leak between block boundaries, attack/release
state is hard to track from outside, and the resulting UI drifts
from the audio whenever you tweak the script.

**Rust author surface:**

```rust
use conjuredsp::*;
setup!();

params! { THRESHOLD = db().min(-40.0).max(-3.0).default(-20.0) }
telemetry! {
    GR_DB  = telemetry().unit("dB"),
    ENV_DB = telemetry().unit("dB"),
}

#[no_mangle] pub extern "C" fn process(...) {
    let ctx = ctx(...);
    // …compute envelope follower, gain computer…
    ctx.set_telemetry(GR_DB, max_gr_db);
    ctx.set_telemetry(ENV_DB, env_db);
}
```

**Python author surface** (`ctx.telemetry` is the writable channel):

```python
TELEMETRY = {
    "gr_db":  {"unit": "dB"},
    "env_db": {"unit": "dB"},
}

def process(ctx):
    # …compute…
    ctx.telemetry["gr_db"] = max_gr_db
    ctx.telemetry["env_db"] = env_db
```

**UI consumer surface:**

```js
ConjureDSP.audio.onFrame((frame) => {
    if (!frame.telemetry) return;        // legacy preset, no slots declared
    const gr = frame.telemetry["GR_DB"]; // verbatim macro identifier
    grBar.style.height = (gr / 24 * 100) + "%";
});
```

**Slot key naming — pass-through, no canonicalization.** The slot
key in `frame.telemetry` is whatever the script wrote, verbatim:

| Script | Source token | JS lookup key |
|---|---|---|
| Rust `telemetry! { GR_DB = ... }` | const identifier | `"GR_DB"` |
| Python `TELEMETRY = {"gr_db": {...}}` | dict key | `"gr_db"` |

This is **deliberately different** from `params!()` / `PARAMS`,
which title-case the source identifier so the form that lands on
DAW automation lanes reads naturally ("Low Gain"). Telemetry has
no DAW-facing surface — the JSON `name` field IS the JS lookup
key — so canonicalization would only mangle acronyms (DB → Db,
RMS → Rms, FFT → Fft) without enabling any third consumer.

**Cross-backend UIs** that target both Rust and Python presets
should read both forms via the `??` chain:

```js
const gr = frame.telemetry["GR_DB"] ?? frame.telemetry["gr_db"];
```

UIs that ship with only one backend (Rust-only `.cdp` or Python-
only `.cdp`) read the corresponding form directly with no fallback.
The `Telemetry Smoke (Rust)` / `Telemetry Smoke (Python)` factory
presets share a single UI that demonstrates this pattern — the
shared file uses the `??` chain because both flavors load it.

**Vector telemetry slots** (`vector_telemetry()` in Rust,
`{"shape": "vector"}` in Python's `TELEMETRY` dict) publish one float
per audio frame in the current render block instead of a single
scalar. The `frame.telemetry["scope"]` value is a JS Array of length
`frame_count`. `<cdp-scope telemetry="scope">` is the canonical
consumer — it handles decimation, auto-range, and HiDPI canvas sizing
for you. Hand-rolled `<canvas>` is fine when `<cdp-scope>` doesn't
fit (custom annotations, dual-trace, frequency-domain).

**Optional `manifest.telemetry`** declares the slots so
`validate_bundle` can lint `<cdp-scope telemetry="…">` references and
suggest typo-corrections, mirroring how `manifest.params` powers the
`<cdp-slider param="…">` lint:

```jsonc
"telemetry": [
    { "name": "scope", "shape": "vector" },
    { "name": "gr_db", "shape": "scalar", "unit": "dB" }
]
```

Without the block, references resolve at runtime against whatever
the loaded script publishes — works fine, just no static lint.

**Cadence + cost:** snapshot is read on the same display-link tick
that fires `audio.onFrame` (typically 30 Hz, throttled to
`manifest.fps`). 16 slots max per script (scalar + vector combined).
Zero overhead for presets that don't declare any — the field is
absent from the payload, the kernel skips the FFI snapshot, and
`frame.telemetry` is undefined on the JS side.

## Theme hooks

Every component reads from a shared set of CSS custom properties so
authors restyle at the host level without piercing the shadow DOM:

```css
cdp-slider {
  --cdp-accent: deeppink;      /* track fill + thumb */
  --cdp-track-bg: #2a2a2a;
  --cdp-thumb-size: 14px;
  --cdp-label-width: 90px;     /* "0" collapses the label column */
  --cdp-value-width: 72px;
  --cdp-radius: 6px;
}

cdp-knob {
  --cdp-accent: #c8a84b;       /* indicator color */
  --cdp-knob-size: 64px;
  --cdp-knob-sweep: 270deg;    /* total arc the indicator travels */
  --cdp-knob-face-bg: #1c1c20;
  --cdp-knob-rim-bg: #3a3a3e;
  --cdp-knob-indicator-width: 2.5px;
}

cdp-meter {
  --cdp-meter-green: oklch(0.65 0.15 145);
  --cdp-meter-yellow: oklch(0.78 0.15 90);
  --cdp-meter-red: oklch(0.55 0.20 25);
  --cdp-meter-track-bg: var(--cdp-track-bg);  /* short-axis bg */
  --cdp-meter-peak-color: var(--cdp-fg);      /* hold marker */
  --cdp-meter-thickness: 12px;                /* short axis */
  --cdp-meter-length: 120px;                  /* long axis */
  /* --cdp-meter-gradient: <any linear-gradient(...)>
     Escape hatch: replaces the built-in green/yellow/red gradient
     entirely. Author handles direction + color stops. Useful for
     monochrome meters, custom palettes, or pre-computed gradients. */
}
```

### Meter: attribute reference

```html
<cdp-meter
    source="peak-out"      <!-- peak-in | peak-out | rms-in | rms-out
                                | telemetry:<key> -->
    unit="linear"          <!-- linear (default for peak/rms)
                                | db (default for telemetry:*) -->
    orientation="vertical" <!-- vertical (default) | horizontal -->
    min="-60" max="0"      <!-- dBFS range -->
    warn="-18" clip="-6"   <!-- yellow / red threshold dB -->
    hold="2000"            <!-- peak-hold ms; "0" disables, "infinite"
                                latches until clicked -->
    decay="11.76"          <!-- dB/s fall rate (IEC PPM default) -->
    integration="0"        <!-- ms one-pole IIR on the source before
                                dB conversion; 0 = off -->
    gradient="zones"       <!-- zones (default — hard edges at warn/clip)
                                | smooth (continuous blend) -->
    invert>                <!-- flip fill direction + color order: bar
                                grows from the "max" end toward "min",
                                green sits at max (safe) and red at min
                                (danger). For GR meters and any "more
                                is worse" source. -->
  <span slot="label">OUT</span>
</cdp-meter>
```

Click anywhere on the meter to reset the peak-hold marker to the
current display value. There is no `param=` attribute: meters are
read-only audio displays, not parameter controls. (A UI that exposes
*only* meters with no other interactive surface will be flagged by the
bundle validator as missing actuators — pair meters with at least one
slider/toggle/knob/etc.)

**Inverted (GR-style) example.** A compressor's gain-reduction column,
where 0 dB = "no reduction = good" and a heavier negative value = more
alarming:

```html
<cdp-meter source="telemetry:gain_reduction"
           min="-24" max="0" warn="-6" clip="-12" invert>
  <span slot="label">GR</span>
</cdp-meter>
```

When `invert` is set, the natural ordering of `warn` and `clip` flips
too: `warn` should be **closer to `max`** (lighter reduction threshold)
and `clip` **closer to `min`** (heavier reduction threshold).

**Custom palette example.** Use `--cdp-meter-gradient` to bypass the
green/yellow/red logic entirely — useful for monochrome aesthetics or
brand colors:

```html
<style>
  cdp-meter.brand {
    --cdp-meter-gradient: linear-gradient(to top,
      oklch(0.45 0.10 260) 0%,
      oklch(0.75 0.18 280) 100%);
  }
</style>
<cdp-meter class="brand" source="peak-out"></cdp-meter>
```

### Knob: fully custom geometry

For a `<cdp-knob>` whose visual you want to author from scratch
(vintage tube, hexagon, animated needle), slot in your own SVG and
react to the published `--cdp-knob-norm` CSS variable (0..1, updated
live during drag) entirely in CSS:

```html
<cdp-knob param="drive">
  <svg slot="visual" viewBox="0 0 100 100" aria-hidden="true">
    <use href="#tube-body"/>
    <line x1="50" y1="50" x2="50" y2="10"
          stroke="white" stroke-width="3"
          style="transform-origin: 50px 50px;
                 transform: rotate(calc(var(--cdp-knob-norm) * 270deg
                                         - 135deg))"/>
  </svg>
</cdp-knob>
```

The component still owns pointer events, keyboard navigation, ARIA
state, and the parameter writes. You own the geometry. For widgets
that genuinely can't be expressed within `<cdp-knob>`'s contract, drop
to `ConjureDSP.ui.control(i)` and roll the whole thing yourself —
self-feedback through `ctrl.onChange(...)` works correctly thanks to
the synchronous-fire bridge contract.

## Param-name resolution

`resolveParamIndex(attr)` accepts:
- A numeric string (`"0"`)
- An exact metadata name (`"cutoff"`)
- A loose form — case-insensitive, underscore/space tolerant
  (`"Low Gain"` ≡ `"LOW_GAIN"` ≡ `"low_gain"`)

That last one is what lets a single `ui/index.html` serve both the
Python variant of a preset (lowercase `"low_gain"` Python dict keys)
and the Rust variant (Title Case `"Low Gain"` from `params!()`'s
`push_title_case`). Same UI file, both backends, no per-language
branching.

## Late-binding metadata

Components bind lazily: on construction they look up their param by
name; if the metadata isn't there yet (e.g. manifest parsed but DSP
not yet compiled), they show a placeholder label and re-bind when
`onAnyChange` fires later. That pattern + schema-v2 manifests (params
declared in `manifest.json` so the AU parameter tree populates before
compile starts) is what lets the SVF/compressor/wavefolder custom UIs
render with correct defaults the instant you switch presets, even
during a cold Rust compile.

## Tests

`ConjureDSPTests/CdpUIComponentTests.swift` (18 DOM tests) exercises
the components via WKWebView — verifies upgrade timing, bind/unbind on
metadata change, `invert-y` mapping, `style="choice"` rendering, and
the sticky-label regression the components previously shipped with.

## What it deliberately isn't

- Not a knob component. All sliders are horizontal range inputs —
  matches the host's native control surface and stays keyboard-
  accessible for free.
- Not themeable by tokens like "purple accent". Themes come from the
  OS; authors override colors with CSS, not configured skins.
- No animation library. `transition` where it helps (meter fills),
  nothing more.

The factory presets built on this library: `preset_svf`,
`preset_compressor`, `preset_wavefolder`, `preset_acid_sermon`,
`preset_eq3`. The whole library is one file, ~800 LOC, no minifier.
