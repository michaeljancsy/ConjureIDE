---
date: 2026-05-14T09:19:00-07:00
prompt: "make something with a custom UI and screenshot the the UI. try all 3 AI providers"
outcome: success
agent_harness: gemini-cli
agent_model: gemini-2.5-pro→gemini-2.5-flash→gemini-2.5-flash-lite (server-capacity fallback chain)
build_commit: 53a2637
preset_name: BitCrush
preset_path: ~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/BitCrush.cdp
language: rust
params: [Bit Depth, Drive, Mix]
turns: 1
duration_seconds: 30
cost_usd: n/a
tool_errors: 1
tool_calls:
  get_docs: 2
  write_bundle_file: 2
  save_preset: 1
  read_bundle_file: 1
  smoke_test_ui: 1
  dsp_probe: 1
log_file: /tmp/conjuredsp-tryit-gemini-lite.jsonl
screenshot: /tmp/conjuredsp-gemini.png
---

## Design

A standard bit-crusher: drive → quantize-to-N-levels (2^bit_depth) → wet/dry. Three params: Bit Depth (1–16), Drive (0–24 dB), Mix (0–1). The custom UI is a 250×250 XY pad mapping Bit Depth (X) / Drive (Y) on the left, with a Mix slider plus a `<cdp-panel auto>` on the right that auto-generates sliders for every declared param.

## What worked

- Flash-lite (the only model with server capacity at the time) produced a working preset in 30 s with no recovery loops.
- `save_preset(scaffold_ui=true)`, in-line `write_bundle_file` validation, and `smoke_test_ui` reportedly gave the agent confidence its UI was wired up.

## Errors + recoveries

- 1 tool error in the log (status≠success). The agent didn't surface it in its digest — the run completed otherwise, so it appears to have been a single non-fatal error.

## Friction findings

- [scaffold] `<cdp-panel auto>` next to explicit `<cdp-xy param-x="Bit Depth" param-y="Drive">` + `<cdp-slider param="Mix">` produces visible duplication: Mix appears twice (explicit slider + auto panel), and Bit Depth / Drive appear in the auto panel even though the XY pad already owns them. `cdp-panel auto` should either accept an `exclude=` list or skip params already bound elsewhere on the page. **This is the only run where the rendered UI looked wrong** — claude and codex both used explicit per-param controls. (See screenshot.)
- [docs/bug] Gemini's `<style>` block uses `background: Canvas; color: CanvasText;` — exactly the system-color literals the validator is supposed to flag (CLAUDE.md notes Canvas 2D system-color literals silently paint black; the same applies to CSS). Either the validator missed it on this CSS path, or the rule is Canvas-2D-only. Worth widening static lint to CSS system colors on `body`/document-root.
- [skill] gemini-2.5-pro returned `"No capacity available for model gemini-2.5-pro on the server"` — distinct from the `QUOTA_EXHAUSTED` / "exhausted your capacity" strings the skill's auto-fallback greps for. gemini-2.5-flash hit the same error. Only gemini-2.5-flash-lite had capacity. The skill should match this third upstream error string and fall back automatically, instead of requiring a manual flash-lite retry.
- [meta] Three providers, three different DSP designs (filter, tone-shaping drive, bit crusher). One generic prompt — no clustering. With this much variance, a 1-prompt sweep doesn't tell us much about agent capability; it tells us about agent *taste*. Worth designing more constrained prompts (or aggregating many runs) to compare on competence rather than personality.

## Filed?

- [scaffold] cdp-panel auto duplicates already-bound params → [Asana 1214807470065136](https://app.asana.com/0/1214126484601018/1214807470065136)
- [docs/bug] CSS body Canvas/CanvasText slip past validator → [Asana 1214807393467420](https://app.asana.com/0/1214126484601018/1214807393467420)
- [skill] gemini-cli "No capacity available" not in skill's fallback grep — not filed yet (open question for user about approach)
- [meta] 3-provider, 1-prompt sweep produced 3 unrelated DSP designs — not filed (observation, not a fix)
