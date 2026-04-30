---
date: 2026-04-29T17:08:35-07:00
prompt: "Build a resonant low-pass filter preset. Use a single biquad lowpass with two parameters: Cutoff (20 Hz to 20 kHz, log curve, default 1 kHz, in Hz) and Resonance (Q from 0.5 to 10, linear, default 0.707). Custom UI: two large `<cdp-knob>` controls side by side, labeled \"Cutoff\" and \"Resonance\"."
outcome: success
agent_harness: codex-cli
agent_model: gpt-5.5
build_commit: 9b3280c
preset_name: TEST_lowpass_python_codex
preset_path: /Users/michaeljancsy/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/TEST_lowpass_python_codex.cdp
language: python
target_language: python
manifest_language: python
params: [Cutoff, Resonance]
turns: 1
duration_seconds: 39
cost_usd: 0.3697
input_tokens: 275819
output_tokens: 2496
tool_errors: 0
tool_calls:
  get_bundle_info: 2
  get_docs: 3
  get_parameters: 1
  get_script: 1
  read_bundle_file: 1
  save_preset: 1
  smoke_test_ui: 1
  write_bundle_file: 2
log_file: /var/folders/xy/n5qmh4g57k128b71zmstk4440000gn/T/tryit-lowpass-python-codex-XXXXXX.jsonl.gyUgtRmn8r
exit_code: 0
---

## Design

(Auto-generated. Subagent's digest follows.)

## Subagent digest (verbatim)

- **What I built:** `TEST_lowpass_python_codex`, Python. Two params: `Cutoff` 20 Hz-20 kHz log default 1 kHz, and `Resonance` Q 0.5-10 linear default 0.707. DSP is a single per-channel `BiquadCoeffs.lowpass` / `Biquad`; UI is two large side-by-side `<cdp-knob>` controls labeled by the params.

- **What worked smoothly:** `save_preset(..., scaffold_ui=true)` created and loaded the bundle cleanly. Runtime UI smoke test passed: both knobs bound, both params covered, no JS errors.

- **Errors hit + recoveries:** The first UI write failed static validation because the scaffolded manifest had no `params` block, so named knob bindings could not resolve statically. I recovered by writing a schema v2 `manifest.json` with explicit param metadata.

- **Tooling/doc/guidance gaps noticed:** `scaffold_ui=true` produced a UI bundle but did not include a manifest `params` block, even though the UI validator requires one for named controls. That mismatch is the main friction point.

## Errors + recoveries

(Tool error count: 0. Inspect log for detail.)

## Friction findings

- [scaffold] `save_preset(scaffold_ui=true)` does not write a `params` block into `manifest.json`, so static UI validation fails on first write of `ui/index.html` with named `param=` references. Required a manual schema-v2 manifest patch — the most-reported friction across all 30 runs.

## Filed?

- [scaffold] manifest.params not auto-populated by scaffold_ui=true → [save_preset(scaffold_ui=true) should populate manifest.params](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214409159717064)
