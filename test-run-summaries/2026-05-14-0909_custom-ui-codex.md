---
date: 2026-05-14T09:09:00-07:00
prompt: "make something with a custom UI and screenshot the the UI. try all 3 AI providers"
outcome: success
agent_harness: codex-cli
agent_model: codex-cli
build_commit: 53a2637
preset_name: Prism Tilt Drive
preset_path: ~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/Prism Tilt Drive.cdp
language: rust
params: [Focus, Tilt, Bite, Drive, Mix, Output]
turns: 1
duration_seconds: 300
cost_usd: n/a
tool_errors: 0
tool_calls:
  get_docs: 4
  get_bundle_info: 2
  write_bundle_file: 2
  dsp_probe: 2
  get_script: 1
  get_audio_state: 1
  save_preset: 1
  get_parameters: 1
  validate_bundle: 1
  smoke_test_ui: 1
log_file: /tmp/conjuredsp-tryit-codex.jsonl
screenshot: /tmp/conjuredsp-codex.png
---

## Design

A 6-param tone-shaping drive: low/high shelf "tilt" pivoted on a movable focus point, a resonant "bite" peak, tanh saturation, wet/dry mix, output trim. The custom UI splits into a "Tone Plane" XY pad (Focus/Tilt) and a "Shape" section with four knobs (Bite, Drive, Mix, Output) plus an output meter on the right. `ui_audio_frames=true` is enabled so the meter has live audio data.

## What worked

- `save_preset(scaffold_ui=true, ui_audio_frames=true)` set up the bundle and loaded the Rust DSP in one shot.
- `validate_bundle` static checks passed; `smoke_test_ui` passed; `dsp_probe` confirmed no NaN/Inf with sensible RMS and a non-zero impulse response.
- Codex hit nearly every diagnostic tool (`get_audio_state`, `get_parameters`, `dsp_probe` twice, `validate_bundle`, `smoke_test_ui`) — most thorough pre-flight of the three providers.

## Errors + recoveries

- First UI validation warned that explicit `cdp-xy::part(puck)` `20px` size was too small. Codex removed the explicit puck dimensions and the warning cleared.

## Friction findings

- [ux] `cdp-xy::part(puck)` size-too-small warning conflicts with the docs' own examples that style the puck at 18 px. The validator wants ≥60 px. (Claude hit the same rule independently — see `2026-05-14-0904_custom-ui-claude.md`.) Either bump the example sizes in the docs, or exempt the puck under `cdp-xy`.
- [ux] `smoke_test_ui` confirms parameter bindings and JS boot but doesn't verify that a `cdp-meter` visually responds to live audio — the agent had to mention this gap explicitly. A "live audio" mode for smoke testing, or a docs callout that meters/scopes need real audio to verify, would close the loop.

## Filed?

- [ux] cdp-xy puck size validator vs docs example → Asana 1214807488581466
- [ux] smoke_test_ui can't verify live-audio components → Asana 1214807745765561 (resolution: inject synthetic audio.onFrame ticks + DOM-probe)
