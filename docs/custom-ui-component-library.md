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
- `requireVersion(n)` — future-proofing; asserts the library is at
  least version `n`.

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
