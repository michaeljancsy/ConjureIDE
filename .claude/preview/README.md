# `.claude/preview/` — in-browser scaffolds for cdp-ui development

Drive `cdp-ui.js` components and custom-preset UIs in a real browser
(headless Chromium via `mcp__Claude_Preview__*`) against a stubbed
`window.ConjureDSP` bridge — no AU build, no WKWebView, no host app.

## When to reach for this

- **Diagnosing a custom-UI bug** when the live plugin's behavior
  doesn't match what static analysis or `smoke_test_ui` predicts.
  Lets you drive synthetic pointer/keyboard/wheel events and watch
  the component's actual DOM state, which the WKWebView smoke test
  can't.
- **Iterating on `cdp-ui.js`** itself. The `cdp-ui.js` file in each
  subdir is a symlink to `ConjureDSPExtension/Resources/cdp-ui.js`,
  so library edits show up on page reload — much faster than the
  ~27-minute `ConjureDSPTests/CdpUIComponentTests` round trip.
- **Verifying a proposed bridge or library change** is safe before
  shipping it, by toggling the new behavior behind a flag in
  `bridge-stub.js` and driving both scenarios in the same session.

NOT a substitute for `ConjureDSPTests/CdpUIComponentTests` — that
target runs the components against the *real* bridge in a *real*
WKWebView and catches things the stub doesn't (Custom Elements
upgrade timing, WebKit pointer-capture quirks, etc.). Use this for
diagnosis and prototyping; let the WKWebView suite be the gate.

## Layout

```
.claude/launch.json                # tracked — defines the server entries
.claude/preview/
  README.md                        # this file
  svf/                             # SVF preset preview
    index.html                       # the preset's HTML (or a copy with bridge wired in)
    cdp-ui.js → ../../../ConjureDSPExtension/Resources/cdp-ui.js
  compressor/                      # general-purpose scratchpad (despite the name)
    index.html                       # whatever's currently being tested
    bridge-stub.js                   # minimal window.ConjureDSP mock
    cdp-ui.js → ../../../ConjureDSPExtension/Resources/cdp-ui.js
```

`launch.json` exposes each subdir on a fixed port (8765 for `svf-ui`,
8766 for `compressor-ui`).

## How to use it

1. Start the server (Claude Preview MCP tool):
   ```
   mcp__Claude_Preview__preview_start { name: "compressor-ui" }
   ```
2. Stage your test page in the corresponding subdir's `index.html`.
   - For preset-specific testing: copy from
     `~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/<name>.cdp/ui/index.html`
     and add `<script src="bridge-stub.js"></script>` +
     `<script src="cdp-ui.js"></script>` before the inline scripts.
   - For library work: write a fresh page that uses the components
     directly (see `compressor/index.html` for an example with
     `<cdp-knob>` and a slotted custom SVG).
3. Drive interactions and inspect state via `preview_eval`:
   ```js
   ConjureDSP.parameters.get(0)
   document.querySelector('cdp-knob').shadowRoot.querySelector('.indicator-group').getAttribute('transform')
   document.elementFromPoint(x, y)
   ```
4. Synthesize input via dispatched events (the page is a real DOM,
   so `PointerEvent` / `KeyboardEvent` / `WheelEvent` all work).
5. `preview_screenshot` for visual sanity checks.
6. `preview_stop` when done.

## The bridge stub

`compressor/bridge-stub.js` mirrors the public surface of the real
`ConjureDSPExtension/Resources/customui-bridge.js`:

- `ConjureDSP.parameters.{count, get, set, metadata, onChange, onAnyChange}`
- `ConjureDSP.audio.{onFrame, offFrame}` (synthetic frames at 30 Hz)
- `ConjureDSP.ready(cb)`, `ConjureDSP.theme`, `ConjureDSP.log(...)`

It mirrors the **production** semantics — `set()` fires onChange
synchronously after a dedupe-on-equal guard, just like the real
bridge. To test alternative bridge behaviors, edit the stub locally
(it's gitignored from the perspective of breaking anything else) and
toggle behavior via a `window.__flag`-style switch.

## Adding a new preview target

1. Create a subdir under `.claude/preview/<name>/`.
2. Add an entry to `.claude/launch.json`:
   ```json
   {
     "name": "<name>-ui",
     "runtimeExecutable": "python3",
     "runtimeArgs": ["-m", "http.server", "<port>", "--directory", ".claude/preview/<name>"],
     "port": <port>
   }
   ```
3. Symlink `cdp-ui.js` so library edits propagate:
   ```bash
   ln -s ../../../ConjureDSPExtension/Resources/cdp-ui.js .claude/preview/<name>/cdp-ui.js
   ```
4. Start with `mcp__Claude_Preview__preview_start { name: "<name>-ui" }`.

## What this scaffold has caught

- The VCA Compressor "knobs don't respond to mouse" bug (Apr 25).
  Synthetic harness verified the preset's HTML/JS was correct, which
  reframed the diagnosis from "preset bug" to "bridge contract gap"
  and led to the synchronous-onChange-on-self-write fix.
- Validated that fix (option C) didn't break cdp-slider's drag thumb
  before shipping it — the 50-iteration drag stress test would have
  caught any normalize/denormalize round-trip drift before it reached
  the WKWebView integration suite.
- Verified `<cdp-knob>` interaction flow (drag, shift-drag, keyboard,
  wheel, dblclick-to-default, slotted-SVG via `--cdp-knob-norm`)
  before any integration-test build cycle.
