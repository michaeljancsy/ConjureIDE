---
date: 2026-05-08T23:05:00-07:00
sweep: 2 prompts × 2 languages = 4 runs (interrupted; original plan was 5×2=10)
harness: claude-code (claude-opus-4-7[1m])
build_commit: 13700b5
runs:
  - 2026-05-08-2245_spectrum-eq-python.md
  - 2026-05-08-2248_spectrum-eq-rust.md
  - 2026-05-08-2253_sidechain-comp-python.md
  - 2026-05-08-2300_sidechain-comp-rust.md
totals:
  turns: 55
  duration_seconds: 730
  cost_usd: 4.96
  tool_errors: 2
  outcomes: 4 success, 0 partial, 0 failed
---

## Aggregate stats

|  # | prompt              | lang   | turns | dur (s) | cost ($) | errors |
|----|---------------------|--------|------:|--------:|---------:|-------:|
|  1 | Spectrum EQ         | python |    12 |     144 |     1.21 |      0 |
|  2 | Spectrum EQ         | rust   |    19 |     260 |     1.70 |      1 |
|  3 | Sidechain Ducker    | python |    13 |     181 |     1.08 |      1 |
|  4 | Sidechain Ducker    | rust   |    11 |     145 |     0.97 |      0 |

All 4 runs hit `success` outcome. Each preset shipped a working DSP + custom UI + telemetry pipeline + persisted state.

## Tool-call distribution (across all 4 runs)

```
get_docs:        15  (≥3 per run; agent always probes docs before authoring)
write_bundle_file: 9  (UI iteration is the dominant edit channel)
smoke_test_ui:    5
save_preset:      4  (one per run)
read_bundle_file: 4  (mostly post-save inspection)
get_script:       3
compile_and_run:  1  (only the Python compressor needed an in-place reload after the param-builder fix)
```

The agent never reached for `get_audio_state`, `set_parameter`, `get_parameters`, `validate_bundle`, `list_presets`, or `list_packages` in any run. Every run was: read docs → save → edit UI → smoke test. The "explore the kernel state" tools sit unused for fresh-build authoring; they're more useful for debugging than authoring.

## What consistently worked

- **`save_preset(scaffold_ui=true)` is the right scaffolding entry point.** Every run started with it. The scaffold gives enough structure (manifest + entry script + ui/index.html stub) that a single `write_bundle_file` of the UI is enough.
- **Telemetry pipeline is reliable.** All 3 runs that needed live visualization (EQ python, EQ rust, both compressors) hit `audio.onFrame` + `ctx.telemetry[...]` round-trip first try. Even the FFT case (`frame.fftIn` with `fft:true`) worked without retries.
- **STATE channel for persistent toggles.** Both EQ runs (bypass) and both compressor runs (link_channels) wired `ConjureDSP.state.set/get` correctly with no friction. The bundle-private STATE design is paying off.
- **`smoke_test_ui` catches the right class of issues.** All 5 invocations returned a clean binding report. Coverage is good enough that the agent trusts it as the final gate.
- **cdp-* component library is well-covered.** Agents reached for `<cdp-meter invert>`, `<cdp-knob>`, `<cdp-slider>` without scaffolding hints.

## Errors + recoveries (2 across 4 runs)

- **Run #2 (Rust EQ):** A generic file-not-found from `Read` (probing for an old local path); not a ConjureDSP MCP error. Self-recovered.
- **Run #3 (Python compressor):** `time_ms(0.5, 50.0)` failed with `param() default 100.0 is outside the declared range`. The conjuredsp Python `time_ms()` builder defaults to `100.0`, which is outside ranges where max < 100. The error message is excellent and self-explanatory. Recovered next turn.

## Friction findings (consolidated, ranked)

**Tier 1 — actual bugs / data loss:**

- **[bug] `save_preset` silently overwrites a different-language bundle with the same name.** Run #4 (Rust Sidechain Ducker) overwrote run #3 (Python Sidechain Ducker). Both used the same preset name "Sidechain Ducker" — the Rust save replaced the Python bundle on disk, no warning, no auto-suffix. The Python compressor is *gone* from the user's library. Either: (a) refuse cross-language overwrite without `replace=true`, or (b) auto-suffix like the EQ runs did ("Spectrum EQ" → "Spectrum EQ 3"). The asymmetry is jarring — sometimes save_preset suffixes, sometimes it overwrites.

**Tier 2 — docs / UX:**

- **[docs] `time_ms(min, max)` carries a hidden `default=100`** that fails validation when min < 100 or max < 100. The error message is great ("Did you mix up mix() (0..1) with pct() (0..100)?") but `get_docs("params")` doesn't show this gotcha — example signatures look like positional `(min, max)` is enough. Either document the default kwarg, or make the builder default to `(min+max)/2` (or `min`) when the static default falls outside `[min, max]`.
- **[docs] Confirm `ctx.sidechain` Python ↔ `ctx.sidechain_connected()` Rust asymmetry is documented.** Both runs landed on the language-correct form, so docs are probably fine, but worth a sanity check that the Python "truthy ctx.sidechain" pattern is explicit.

**Tier 3 — observations:**

- **[meta] Strong design priors converge across runs.** Both EQ runs landed on the same UI: log-freq canvas + 9 color-banded knobs + cookbook-curve overlay on FFT. Both compressor runs landed on three side-by-side vertical meters (Main / SC / GR). Agent has reliable instincts for these conventional layouts; the cdp-ui library doesn't pre-suggest them — they emerge.
- **[meta] Rust runs are not strictly slower than Python runs in this set.** EQ: Rust 260s vs Python 144s (1.8×). Compressor: Rust 145s vs Python 181s (0.8×). Compile latency is real for Rust but isn't the dominant cost — a cleanly-architected design saves more turns than a fast compile.
- **[meta] Zero use of the "kernel inspection" tools.** Across 55 turns, no `get_audio_state`, `get_parameters`, `set_parameter`, `validate_bundle`, `list_presets`, `list_packages`. Authoring-from-scratch flows don't need them; they're debug-time tools.
- **[meta] `save_preset(scaffold_ui=true)` is sufficient as the primary entry point.** No run reached for an alternative.

## Recommended Asana tickets

If the user wants any filed:

1. **[Bugs] save_preset must not silently overwrite bundles of a different language** — pointer to `2026-05-08-2300_sidechain-comp-rust.md`.
2. **[UX] conjuredsp.params.time_ms / db / freq builders: surface the implicit default in the error path or in get_docs("params")** — pointer to `2026-05-08-2253_sidechain-comp-python.md`.

## Run-level files

- [Run 1: Spectrum EQ (Python)](2026-05-08-2245_spectrum-eq-python.md)
- [Run 2: Spectrum EQ (Rust)](2026-05-08-2248_spectrum-eq-rust.md)
- [Run 3: Sidechain Ducker (Python)](2026-05-08-2253_sidechain-comp-python.md)
- [Run 4: Sidechain Ducker (Rust)](2026-05-08-2300_sidechain-comp-rust.md)
