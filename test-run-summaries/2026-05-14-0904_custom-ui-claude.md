---
date: 2026-05-14T09:04:00-07:00
prompt: "make something with a custom UI and screenshot the the UI. try all 3 AI providers"
outcome: success
agent_harness: claude-code
agent_model: claude-opus-4-7[1m]
build_commit: 53a2637
preset_name: Nebula Filter
preset_path: ~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/Nebula Filter.cdp
language: rust
params: [Cutoff, Resonance, Drive, Mix]
turns: 9
duration_seconds: 163
cost_usd: 0.89
tool_errors: 0
tool_calls:
  get_docs: 3
  save_preset: 1
  write_bundle_file: 1
  dsp_probe: 1
  smoke_test_ui: 1
log_file: /tmp/conjuredsp-tryit-claude.jsonl
screenshot: /tmp/conjuredsp-claude.png
---

## Design

A 4-knob filter+saturation effect: biquad lowpass (Cutoff 40–18 kHz log, Resonance Q 0.5–12) → tanh drive (0–24 dB) → wet/dry crossfade. The custom UI is a "nebula" theme: dark canvas backdrop with twinkling stars, a glowing filter-response curve overlaid on an XY pad (cutoff/resonance drag both controls at once), and two themed knobs for Drive/Mix. The response curve is computed from the same biquad LPF magnitude formula on every `onChange`, so DAW automation animates the curve identically to drag input.

## What worked

- `save_preset(scaffold_ui=true)` followed by `write_bundle_file('ui/index.html', …)` was a single clean atomic flow with no kernel-vs-bundle drift.
- `dsp_probe` with a sine confirmed the LPF was attenuating (out_rms < in_rms) and producing no NaN.
- `smoke_test_ui` passed first try — all 4 params bound, no JS errors, `ready` fired at 77 ms.
- `ConjureDSP.ui.control(name).onChange` was an effective single redraw hook for both user drag and DAW automation.

## Errors + recoveries

- None on the agent's side.

## Friction findings

- [ux] `control_explicit_size_too_small` validator rule fires on `cdp-xy::part(puck)` even when the puck is just a visual marker on a large pad — the pad surface itself is the hit target. Authors get pushed toward an oversized puck that visually dominates the pad. Suggest exempting the puck under `cdp-xy`, or downgrading to info-level. (Codex hit the same warning independently.)
- [skill] Agent saw `persist_inplace!` in the on-disk agent-workspace AGENTS.md / CLAUDE.md / GEMINI.md, but `PTYManager.contextContent` was renamed to `persist_mut!` after these workspace files were last written. The skill's preflight only catches *missing* workspace files (skill body says "Open the terminal pane in the AU once… then re-run"), not stale ones. All 3 agents this sweep got outdated guidance. Fix: have /try-it programmatically trigger `writeAgentWorkspace()` before dispatching, or diff the workspace files against PTYManager source and warn if drift detected.
- [docs] `get_docs("ui")` is ~46k chars and well organized but lacks a "quickstart" at the top. The 5-line recipe (scaffold → write index.html → smoke_test) is buried after the manifest section. On a return visit to the docs an agent has to re-skim to find that recipe — a quickstart at the top would let the second-visit case be 2 seconds instead of one tool round-trip.

## Filed?

- [ux] cdp-xy puck size validator vs docs example → Asana 1214807488581466
- [skill] stale agent-workspace files → Asana 1214807472125116 (resolution: replace on-disk files with an MCP `read_context` tool)
- [docs] get_docs("ui") quickstart → Asana 1214807582518925
