---
date: 2026-05-07T17:44:00-07:00
prompt: "Build a multi-mode filter (LP / HP / BP) with cutoff and resonance controls. Add 4 numbered snapshot buttons (1, 2, 3, 4): clicking a button recalls a stored cutoff/resonance pair into the active filter; shift-clicking stores the current cutoff/resonance to that slot. The 4 stored snapshots and the index of the currently-active slot should persist across DAW project saves via STATE."
outcome: partial
agent_harness: claude-code
agent_model: claude-opus-4-7[1m]
build_commit: 1612dbc
preset_name: Filter Snapshots
preset_path: ~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/Filter Snapshots.cdp
language: python
params: [cutoff, resonance, mode]
turns: 18
duration_seconds: 166
cost_usd: 1.37
tool_errors: 2
tool_calls:
  get_docs: 4
  save_preset: 2
  compile_and_run: 1
  write_bundle_file: 1
  smoke_test_ui: 1
log_file: /var/folders/xy/n5qmh4g57k128b71zmstk4440000gn/T/conjuredsp-tryit-log-XXXXXX.jsonl.XX3gXT9RdN
---

## Design

A 3-mode (LP/HP/BP) biquad filter with `cutoff`, `resonance`, and `mode` as host params plus four numbered snapshot buttons in the custom UI. STATE holds three keys: `snap_cutoff[4]`, `snap_resonance[4]`, and `active`. Plain-click on a numbered button recalls the stored pair (drives `cutoff.setValue`/`reso.setValue`) and updates `active`; shift-click writes the current cutoff/resonance into that slot. The active button highlights and the highlight re-syncs via `state.onChange('active', …)`. STATE is the only place those four snapshots live — they aren't host-automatable, which is exactly the use case the channel was designed for.

## What worked

- `compile_and_run` Python iteration was instant; the agent could try a STATE shape, see it work, and move on without rebuilding.
- `cdp-slider` / `cdp-choice` `param=`-by-name binding plus `ConjureDSP.ui.control('cutoff').setValue(...)` made the snapshot recall side trivial — no manual normalization.
- `state.onChange` synchronous fire was used for the active-slot highlight; agent didn't have to invent a separate UI state mirror.
- `smoke_test_ui` came back `pass` first try after the UI write.
- The PR's HIGH-severity fullState mirror sync wasn't directly exercised in this run (no DAW project save/restore), but the agent never hit the cross-DAW bug surface.

## Errors + recoveries

- Subagent's first attempt was Rust. `state_struct! { … }` failed to compile with two cascading errors: unresolved `serde` / `serde_json`, and a `Default` impl conflict because the macro derives `Default` and the doc example also hand-writes `impl Default`. Recovered by rewriting in Python where `STATE = {…}` "just works."
- Agent's two `tool_errors` events both came from the failed Rust `compile_and_run`s before pivoting to Python.

## Friction findings

- [bug] Saved bundle is internally inconsistent: `manifest.language` = `"rust"`, `manifest.entry` = `"process.rs"`, but the file at `process.rs` contains Python source (`from conjuredsp import …`). The agent successfully transferred the running script to Python via `compile_and_run` + `write_bundle_file`, but the manifest never got rewritten on the second `save_preset`. On reload, the kernel will try to compile the file as Rust and fail — exactly the silent-fallback case this PR's passthrough fix was meant to make visible. (Also: the 7-arg-style "stale audio" bug is now structurally impossible thanks to `PassthroughBackend`, so this is "just" a save bug, not a confused-audio bug.)
- [docs] `get_docs` Rust STATE example actively misleads — the macro emits `#[serde(...)]` attrs but the WASM build environment doesn't link `serde`/`serde_json`, so every `state!()` / `state_struct!` preset fails to compile. Either the macro stops emitting serde attrs, or the build links serde, or the doc needs a "Rust STATE not currently available" warning at the top of the section.
- [docs] The Rust STATE doc example shows `state_struct! { … } impl Default for State { … }`, but the macro itself derives `Default`, producing E0119 conflicting impls. The example wouldn't compile even if serde were present.
- [ux] `validate_bundle` reports `state_keys_unparseable` against a textbook `STATE = {"key": default, …}` declaration whose values include list literals. The lint's suggestion text claims that exact shape *is* parseable, so the message contradicts itself. Non-blocking (warn) but confusing.
- [docs] `get_docs` topic list doesn't include `state` — STATE only appears under `all`, and the error message on an unknown topic doesn't hint at it. A first-class `state` topic would have saved the agent a round-trip and biased it toward Python earlier.
- [meta] Subagent independently chose Python after one Rust failure rather than diagnosing the toolchain issue. Once Python was on the table the run was fast (~3 min, single smoke pass). For STATE-channel presets, Python looks like the path of least resistance from a fresh-context agent.

## Filed?

- [bug] manifest.language/entry not rewritten on save → [save_preset doesn't update manifest.language/entry when script language changes](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214622834383370)
- [bug] Rust state_struct! macro broken → [Rust state_struct! macro fails to compile (serde unresolved + Default conflict)](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214622807859822)
- [ux] validate_bundle warning contradicts suggestion → [validate_bundle 'state_keys_unparseable' warning contradicts its own suggestion text](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214623075491710)
- [ux] add `state` get_docs topic → [Add `state` as first-class get_docs topic](https://app.asana.com/1/946492598125108/project/1214126484601018/task/1214623075413980)
