---
date: 2026-05-12T21:04:40-07:00
prompt: "Write a single-pole lowpass filter in Rust with one parameter (cutoff frequency, 20-20000 Hz, log curve, default 1000 Hz). Apply it per-channel with persistent state. Then save as a preset named \"try-it-rust-lowpass\" and run dsp_probe to confirm it produces non-zero output on a sine input."
outcome: success
agent_harness: claude-code
agent_model: claude-opus-4-7[1m]
build_commit: 389f90d
preset_name: try-it-rust-lowpass
preset_path: /Users/michaeljancsy/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/try-it-rust-lowpass.cdp
language: rust
params: [Cutoff]
turns: 5
duration_seconds: 29
cost_usd: 0.5451512500000001
tool_errors: 0
tool_calls:
  get_docs: 1
  save_preset: 1
  dsp_probe: 1
log_file: /var/folders/xy/n5qmh4g57k128b71zmstk4440000gn/T/conjuredsp-tryit-log-XXXXXX.jsonl.B4vV05WrFk
---

## Design

Validation run after fixing the deprecated-API teaching in `PTYManager.contextContent` (see Asana task 1214757100148499 + DocsDriftGuardTests new `agentWorkspaceTeachingContextIsClean`). Subagent built a one-pole IIR (`y += alpha·(x − y)`, `alpha = 1 − exp(−2π·fc/sr)`) with a single `freq()` Cutoff parameter. Per-channel state held in `persist!(STATE: [f64; 2] = [0.0; 2])`. `dsp_probe` with a sine input returned RMS 0.31, no NaN/Inf.

## What worked

- Single `save_preset` call with inline `source` was atomic — bundle written, preset switched, kernel reloaded, params populated in one shot.
- First compile passed. Zero recovery cycles burned on `#[unsafe(no_mangle)]` or duplicate-static errors (the symptom the original Goniometer run from 2026-05-12-1839 hit).
- Subagent reached for the modern primitives on first try: `process! { ctx => … }`, `params! { CUTOFF = freq() }`, `persist!(STATE: …)` — exactly the API shape the newly-modernized AGENTS.md teaches.
- `dsp_probe` confirmed audio in one call. Verified by passing a sine through a ~1 kHz lowpass; output RMS 0.31 matches expected slight attenuation.

## Errors + recoveries

(Tool error count: 0. Clean run.)

## Friction findings

- [docs] `get_docs("filters")` only covers `Biquad`. The single-pole IIR (`y += alpha·(x − y)` with `alpha = 1 − exp(−2π·fc/sr)`) is one of the most common DSP intro tasks, but there's no documented snippet — a reader could overshoot to `Biquad::lowpass` even when the spec literally says "single-pole." Worth a small section in `filters` or `utilities`.
- [docs] `persist!` example in CLAUDE.md uses `[Biquad; 2]`, which implies "this is for filter objects." It took a beat to confirm it works for plain `[f64; 2]` state. A second example with a scalar/array (e.g. `persist!(PREV: [f64; 2] = [0.0; 2])`) would clarify the broader use case.
- [docs] `params! { CUTOFF = freq() }` emits a `const CUTOFF: usize` (used as `ctx.param(CUTOFF)`), but nowhere in the visible docs is this explicitly stated. Subagent inferred it from the CLAUDE.md example. An explicit "the macro emits `const <NAME>: usize` for each param" line would close the gap.
- [meta] Post-fix run took 5 turns and 29 s vs. the Apr 29 lowpass-rust-claude baseline (14 turns, 95 s) for a comparable filter task. Most of that delta was the baseline burning turns recovering from `static mut` warnings and the wider param list — but it's a useful directional signal that the modernized teaching surface measurably tightens first-shot success.

## Filed?

(Pending — these are the same docs gaps from prior runs; check Asana for existing tickets before filing duplicates.)
