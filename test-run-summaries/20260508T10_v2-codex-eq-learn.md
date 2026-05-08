---
date: 2026-05-08T10:57:57-07:00
prompt: "Build a 4-band parametric EQ. Each band has a \"Learn\" button: pressing it captures the loudest input frequency over the next ~200 ms and locks the band's center frequency to that value. The 4 captured center frequencies persist across DAW project saves via the STATE channel."
outcome: partial
agent_harness: codex
agent_model: codex-cli
build_commit: 4d1a924
sweep: v2 (post-fixes)
preset_name: (none)
preset_path: (no bundle landed)
language: ?
params: (none / no manifest)
turns: 1
duration_seconds: 0
cost_usd: n/a
tool_errors: 0
input_tokens: 1006779
output_tokens: 8115
tool_calls:
  read_bundle_file: 6
  get_docs: 5
  get_bundle_info: 3
  get_parameters: 3
  get_script: 2
  write_bundle_file: 2
  smoke_test_ui: 2
  list_presets: 1
  save_preset: 1
  get_audio_state: 1
  compile_and_run: 1
  validate_bundle: 1
log_file: /var/folders/xy/n5qmh4g57k128b71zmstk4440000gn/T/conjuredsp-tryit-v2-p3-codex-XXXXXX.jsonl.Cd6RkW6HUE
---

## Subagent digest

- **What I built:** `Learn EQ 4-Band`, Python. Parameters: `Gain1/Q1`, `Gain2/Q2`, `Gain3/Q3`, `Gain4/Q4`. The DSP is a 4-band peaking EQ; each band’s center frequency is read from `STATE.freqs`. The custom UI has per-band `Learn` buttons that listen to the input FFT for ~220 ms, pick the loudest bin, and write the captured centers back to STATE so DAW project saves persist them.

- **What worked smoothly:** STATE was a good fit once the direction was clear: UI writes, DSP reads. Static validation and `smoke_test_ui` both pass, and the loaded bundle reports `kernel_in_sync: true`.

- **Errors hit / recovery:** The first version did FFT work inside `process()`, which is not real-time safe. I moved frequency detection into the UI audio-frame path. After rewriting the manifest/UI, the live AU parameter tree stayed on the previous 12-param shape until I forced a `compile_and_run`; then it rebuilt correctly to 8 params.

- **Tooling/doc/guidance gaps:** The UI docs mention `{ fft: true }` but don’t define the FFT frame payload shape (`frame.fftIn`, bin units, sample-rate field), so I had to infer it from an older local preset. Also, `save_preset` over an existing bundle left enough stale parameter-tree state that an explicit reload was needed. `smoke_test_ui` confirms UI binding/runtime boot, but not actual learn behavior with live audio; please play audio and press Learn to confirm the frequency readouts move as expected.
