---
date: 2026-05-13T11:00:30-07:00
prompt: "i'm doing voiceover work from home and i need something that catches it when i get too loud and pulls it back so it sounds even, but i don't want my voice to sound weird or squished. also the s sounds are kind of harsh, can it fix those too? basically one preset i can just put on every vocal take"
outcome: success
agent_harness: codex-cli
agent_model: codex-cli (no model field surfaced)
build_commit: 0deb3ba
preset_name: Home Voiceover Leveler
preset_path: ~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/Home Voiceover Leveler.cdp
language: rust
params: [Target, Loud Catch, Peak Ceiling, De Ess, Sibilance Freq]
turns: 1 (single codex `turn.completed`, but 10 tool-call items inside)
duration_seconds: ~180
cost_usd: n/a
tool_errors: 0
tool_calls:
  get_docs: 3
  dsp_probe: 3
  save_preset: 1
  get_script: 1
  get_parameters: 1
  get_bundle_info: 1
log_file: /var/folders/xy/n5qmh4g57k128b71zmstk4440000gn/T/conjuredsp-tryit-log-codex-XXXXXX.jsonl.o0TvGog5Y0
---

## Design

Three-stage broadcast-style vocal chain in one preset:
1. **Gentle RMS leveler** anchored to `Target` (−30..−12 dB, default −18) with `Loud Catch` (0..100%, default 55) governing how aggressively loud bursts are pulled back.
2. **Fast peak safety stage** to `Peak Ceiling` (−12..0 dB, default −3).
3. **Split-band de-essing**: `Sibilance Freq` (log 4500..9500 Hz, default 6500) defines the sibilance band; `De Ess` (0..100%, default 50) only ducks above that crossover, so the body of the voice keeps its full level. Codex made the "single preset for every take" framing literal — five clearly-labeled knobs, all linear-scale except `Sibilance Freq` which is log.

## What worked

- Probe-driven workflow: `dsp_probe` ran 3 times (sine + impulse + check after save_preset), confirming `has_nan=false`, `has_inf=false`, sensible RMS, and `kernel_in_sync: true` before reporting done.
- `get_bundle_info` + `get_parameters` used as verification step after `save_preset` to confirm the bundle ended up in expected state.
- Most-explicit parameter design of the three runs — every knob has a dB / % / Hz unit; min/max ranges are tight and human-scaled rather than 0–1 generic.

## Errors + recoveries

_None — clean run, no compile/save/validation errors._

## Friction findings

- [meta] Codex was the only harness to volunteer the right limitation: "`dsp_probe` confirms signal health and broad gain behavior, but it cannot judge whether a real voice sounds natural or 'not squished.' That still needs a spoken test take." Worth pulling into AGENTS.md as a stock disclaimer for dynamics / de-essing / saturator presets.
- [meta] All three sweep runs defaulted to Rust per AGENTS.md guidance — but this is the only one whose param set arguably *needed* Rust (compile cost amortized over 5 knobs and 3 DSP stages). For prompt #1 ("voice bigger") and prompt #2 ("underwater guitar") Python would have iterated faster; the global default may be over-tuned toward Rust.
- [meta] Codex didn't call `get_docs("ui")` or scaffold a custom UI. None of the three did. For a "leveler / de-esser" UI the canonical surface would be 2× gain-reduction meters + dB readouts, but the agent stopped at the default slider panel. Same scaffolding-non-invocation pattern as the other two runs.

## Filed?

(Revised 2026-05-13 after opus subagent critique pass — scaffold_ui ticket narrowed.)

- [meta] AGENTS.md addendum — scaffold_ui on UI-shape prompt cues → [Asana 1214782875108753](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214782875108753) (UX, three-run signal; scope narrowed — dropped ≤3-params auto-rule, added MIDI hardware-knob carve-out)
- [meta] `dsp_probe` ≠ naturalness — agents should disclaim "audition with real take" for dynamics/de-esser → not filed (observation worth carrying forward but not actionable as a single ticket; revisit if it shows up in user feedback)
- [meta] Rust-default may be over-tuned for simple prompts → not filed (needs more data; track in future sweeps)
