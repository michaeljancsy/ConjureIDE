---
date: 2026-05-13T10:57:30-07:00
prompt: "i want my guitar to sound like its underwater but not too crazy. i should be able to turn it up and down with a knob"
outcome: success
agent_harness: claude-code
agent_model: claude-opus-4-7[1m]
build_commit: 0deb3ba
preset_name: underwater_guitar
preset_path: ~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/underwater_guitar.cdp
language: rust
params: [Depth]
turns: 7
duration_seconds: 48
cost_usd: 0.66
tool_errors: 0
tool_calls:
  get_docs: 3
  save_preset: 1
  dsp_probe: 1
log_file: /var/folders/xy/n5qmh4g57k128b71zmstk4440000gn/T/conjuredsp-tryit-log-claude-XXXXXX.jsonl.LHT1pCAi9M
---

## Design

Single-knob "macro" preset. `Depth` (0–100%, default 50) drives three derived params simultaneously: a stereo lowpass that ramps from 18 kHz → 600 Hz on a log scale, a chorus-style modulated delay (12 ms base + ±6 ms LFO swing) with two slightly-detuned LFOs (0.35 Hz / 0.47 Hz) for per-channel decorrelation, and a dry/wet crossfade ramping 0% → 85% wet so the extreme is murky but the guitar is still recognizable. UI is the default cdp generic slider panel — no `scaffold_ui=true`, so the prompt's "knob" intent renders as a slider.

## What worked

- First-try success: `params!` / `persist!` / `persist_buf!` / `process!` macro composition compiled clean on attempt #1.
- `save_preset` accepted source + name in one call (no separate write_bundle_file).
- `dsp_probe` (`signal: "sine"`) confirmed no NaN/Inf and sane RMS at default `Depth=50%` in one call — the AGENTS.md "always probe after a non-trivial compile" guidance landed.
- Fewest tool calls of the three runs (5 total, excluding 1 ToolSearch built-in).

## Errors + recoveries

_None — compiled and probed on the first attempt._

## Friction findings

- [docs] **No "one knob, many derived coefs" example in `get_docs("params")`.** The agent had to invent the macro-param idiom from scratch. A 10-line example showing `let depth = ctx.param(DEPTH); let cutoff = lerp(18000.0, 600.0, depth); ...` would compress future runs.
- [docs] **`persist!` vs `persist_buf!` threshold is unstated.** Agent guessed `persist_buf!` for a 4096-sample `DelayLine`; an explicit rule of thumb ("any `[T; N]` with N > 32 or > a few hundred bytes") would remove the guesswork. (Also flagged in the gemini run — duplicate signal.)
- [ux] **`Lfo::new()` defaults to 44100 Hz and silently mis-tunes if `.init(sr, freq)` isn't called.** Easy to skip; the failure is "wrong pitch, but valid audio" — invisible to `dsp_probe`. Compile-time or first-tick guard preferred to a docs note.
- [meta] Prompt explicitly said "turn it up and down with a knob"; agent saved with default `style: "slider"` and no scaffold_ui. No agent in this sweep upgraded to a knob UI for the explicit-knob prompt — suggests the scaffolding entry point isn't surfaced strongly enough in AGENTS.md.

## Filed?

(Revised 2026-05-13 after opus subagent critique pass — titles + scope updated; severity downgrade on Lfo bug.)

- [docs] State size/perf threshold for persist! vs persist_buf! (not Copy vs non-Copy) → [Asana 1214782996911434](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214782996911434) (UX, two-run signal w/ Gemini)
- [bug] Lfo::new() hardcodes 44.1 kHz; skipping .init(sr,…) → silent wrong-pitch → [Asana 1214782922470620](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214782922470620) (Bugs; severity downgraded — no factory preset is broken, Option B in original fix was dead code in user WASM)
- [meta] AGENTS.md addendum — scaffold_ui on UI-shape prompt cues → [Asana 1214782875108753](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214782875108753) (UX, three-run signal; narrowed — dropped ≤3-params rule, added MIDI carve-out)
- [docs] No "one macro-param drives many derived coefs" example → not filed (single-run signal; will track if it repeats)
