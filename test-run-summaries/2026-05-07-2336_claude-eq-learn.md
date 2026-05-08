---
date: 2026-05-07T23:36:00-07:00
prompt: "Build a 4-band parametric EQ. Each band has a \"Learn\" button: pressing it captures the loudest input frequency over the next ~200 ms and locks the band's center frequency to that value. The 4 captured center frequencies persist across DAW project saves via the STATE channel."
outcome: success
agent_harness: claude
agent_model: claude-opus-4-7[1m]
build_commit: d6061ec
preset_name: Learn EQ.cdp
preset_path: ~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/Learn EQ.cdp
language: python
params: [Gain1, Q1, Gain2, Q2, Gain3, Q3, Gain4, Q4]
turns: 18
duration_seconds: 372
cost_usd: 1.20
tool_errors: 0
tool_calls:
  get_docs: 4
  write_bundle_file: 3
  get_error: 2
  get_script: 1
  list_packages: 1
  save_preset: 1
  read_bundle_file: 1
  smoke_test_ui: 1
log_file: /var/folders/xy/n5qmh4g57k128b71zmstk4440000gn/T/conjuredsp-tryit-p3-claude-XXXXXX.jsonl.qfcgdQjDA5
---

## Subagent digest

Build is clean. Smoke test passes; no JS errors; all 8 params bound; no kernel error.

## Digest

**What I built**
- Preset name: **Learn EQ** (Python)
- 8 user params: `gain1..4` (-18..+18 dB) and `q1..4` (0.3..10) — one peaking biquad per band, cascaded via `scipy.signal.sosfilt` so all 4 bands are vectorized over the block (no per-sample Python loop).
- 4 center frequencies live in the **STATE channel** (`f1..f4`, defaults 200/800/3000/8000 Hz) — STATE persists with the DAW project, not the bundle, which is exactly what was asked for.
- DSP publishes `peak_freq` telemetry every ~4 blocks: 4096-sample Hann-windowed `np.fft.rfft` of the input ring buffer, DC + first bin zeroed, argmax → Hz. Bin resolution at 44.1 kHz is ~10.8 Hz.
- Custom UI (520×360 pt): one row per band — index, **Learn** button, current freq readout, gain slider, Q slider. Learn button arms a 220 ms capture window, accumulates `peak_freq` telemetry samples, takes the median, writes it back to STATE. The DSP picks up the new center freq on its next block via `ctx.state["fN"]`.

**What worked smoothly**
- `save_preset(scaffold_ui=true, source=...)` in one call gave me a working bundle on disk + kernel-loaded script + manifest.params populated, no coordination dance.
- The validation report inlined in `write_bundle_file` caught my first bug instantly (template-literal `param="gain${i}"` is invisible to the static scan; rewrote the bands as four explicit `<div>` blocks and it passed).
- `smoke_test_ui` confirmed `ready` fired, all 8 params bound, no JS errors. ~76 ms ready time.
- The UI architecture — DSP publishes peak freq continuously via telemetry, JS captures samples for ~200 ms on Learn click, writes median to STATE — neatly sidesteps the "scripts can't write STATE from `process()`" rule. Every responsibility lives where it can act.

**Errors hit + recovery**
- Static lint failed on the template-literal `<cdp-slider param="gain${i}">` because the validator scans the raw HTML before JS runs. Recovery: replaced the JS-generated rows with four hand-written `<div class="band">` blocks. Net code didn't get longer.

**Tooling / doc / guidance gaps (the friction signal)**
1. **The "DSP can't write STATE from process()" constraint forces a UI-mediated learn loop.** That's a fine boundary for lock-free reads, but the docs frame STATE as the persistence answer for "captured impulse responses, MIDI learn maps" — both of which are *exactly* the case where the analysis lives in DSP and the natural impulse is to write the result back to STATE from `process()`. The MIDI-learn example in the state doc is misleading; it works only with a UI middleman like I built. Worth either an explicit example showing the telemetry→UI→state.set round-trip, or a sanctioned `ctx.request_state_write(key, value)` that the kernel applies between blocks.
2. **The static UI-coverage validator can't see JS-generated `<cdp-*>` elements.** That's documented (the "hand-rolled bindings need a declarative twin" section) but the failure mode for *templated* `param="gain${i}"` is the same — and there's no specific note saying "even in JS that synthesizes cdp-* elements, write the bindings as static HTML for the validator." A one-line callout would have saved a write/validate cycle.
3. **`audio.onFrame` doesn't appear to return an unsubscribe function** (or if it does, it's not in the docs I read). I worked around it by keeping a single global subscriber and routing samples into per-band capture arrays only while a learn is active. Whether that's the intended pattern or just a workaround for a missing affordance isn't clear from the docs.
4. **Telemetry slot name canonicalization rules differ from param-name rules.** Params are loose-matched (case/underscore insensitive); telemetry is exact-string (Python uses the dict key verbatim, Rust uses the macro identifier verbatim). The docs do call this out, but it's a footgun — I almost wrote `frame.telemetry.peakFreq` from muscle memory.
5. **No way to verify "does audio actually flow through the new filters" without the user playing audio.** `smoke_test_ui` is binding-only, as the CLAUDE.md flagged. For a feature whose entire value is "Learn finds the right frequency," I can ship code that compiles and binds cleanly while still being subtly wrong (e.g., wrong FFT bin formula, biased peak picker). A `probe_audio(input_signal, duration)` MCP tool that ran the kernel against a synthetic tone and returned a few telemetry samples would close that loop without requiring the user to drag a sine generator into the DAW.
