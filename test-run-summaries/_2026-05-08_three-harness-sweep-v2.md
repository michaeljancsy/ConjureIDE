---
title: Three-harness sweep v2 — claude / codex / gemini × 5 prompts (post-fix re-run)
date: 2026-05-08T11:20:00-07:00
build_commit: 4d1a924
sweep: v2 (post-fix)
total_runs: 15
v1_baseline: _2026-05-07_three-harness-sweep.md
---

# Three-harness sweep v2 — comparing against v1 baseline

Identical 5 prompts to the v1 sweep on `d6061ec`, re-run on `4d1a924` after landing
fixes for the friction findings v1 surfaced:

- Rust STATE typed accessors (`cx.state_array_u8::<N>`, `cx.state_int`, …) so Rust isn't
  the second-class state path
- `telemetry!()` empty-form arms so the macro stops ping-pong-ing
- `parseRustStateKeys` skip — Rust scripts no longer trigger `state_keys_unparseable`
- `smoke_test_ui` captures `console.log` with stringified objects (no more `[object Object]`)
- Agent-workspace `AGENTS.md` now explicitly tells agents to call `save_preset` after `compile_and_run`

## Side-by-side outcomes (v1 → v2)

| Prompt | Harness | v1 outcome | v2 outcome | v1 turns | v2 turns | v1 cost | v2 cost |
|---|---|---|---|---:|---:|---:|---:|
| p1 | claude | ok | ok+saved | 11 | 19 | $0.87 | $1.62 |
| p1 | codex | ok | ok+saved | 1 | 1 | — | — |
| p1 | gemini | ok | ok·no-save | 17 | 20 | — | — |
| p2 | claude | ok | ok+saved | 9 | 16 | $1.00 | $1.14 |
| p2 | codex | ok | ok+saved | 1 | 1 | — | — |
| p2 | gemini | ok | FAIL | 30 | — | — | — |
| p3 | claude | ok | ok+saved | 18 | 15 | $1.20 | $1.21 |
| p3 | codex | ok | ok·no-save | 1 | 1 | — | — |
| p3 | gemini | ok | ok·no-save | 32 | 0 | — | — |
| p4 | claude | ok | ok+saved | 17 | 13 | $1.21 | $1.01 |
| p4 | codex | ok | ok·no-save | 1 | 1 | — | — |
| p4 | gemini | ok | FAIL | 36 | — | — | — |
| p5 | claude | ok | ok+saved | 34 | 19 | $2.12 | $1.46 |
| p5 | codex | ok | ok+saved | 1 | 1 | — | — |
| p5 | gemini | ok | FAIL | 17 | — | — | — |

## Notable

- **gemini-2.5-pro quota exhausted** mid-sweep (3 of 5 runs failed with API 429 / 12h reset). Pro 's daily quota is tight enough that 2 successful + 3 failed runs is a real limit. p1 and p3 ran. Consider switching to `gemini-2.5-flash` for sweeps or splitting across days.
- **Gemini p1-v2 lost MCP tool visibility** — the agent reported `conjuredsp__*` tools "are not available in my environment" despite `gemini mcp list` showing the server connected. Did 0 MCP tool calls but 20 `run_shell_command` calls trying to discover the API. Same agent did fine in v1 (17 MCP calls, saved a bundle). Possible flap in gemini's MCP-tools-into-prompt machinery; worth re-running once quota resets to confirm.
- **Claude turns / cost up across the board v1 → v2.** Avg v1 was 18 turns / $1.28. Avg v2 is 16 turns / $1.29. Net: similar cost, slightly fewer turns — the new Rust STATE helpers + cleaner docs aren't free in input tokens but did pay back in iterations avoided.
- **Codex still doesn't surface a per-run cost.** Tokens (cached + fresh) are recorded; would need a per-model rate sheet to estimate spend.

## Per-run summaries

- [p1 / claude (v2)](20260508T10_v2-claude-gate-seq.md)
- [p1 / codex (v2)](20260508T10_v2-codex-gate-seq.md)
- [p1 / gemini (v2)](20260508T10_v2-gemini-gate-seq.md)
- [p2 / claude (v2)](20260508T10_v2-claude-ab-snapshot.md)
- [p2 / codex (v2)](20260508T10_v2-codex-ab-snapshot.md)
- [p2 / gemini (v2)](20260508T10_v2-gemini-ab-snapshot.md)
- [p3 / claude (v2)](20260508T10_v2-claude-eq-learn.md)
- [p3 / codex (v2)](20260508T10_v2-codex-eq-learn.md)
- [p3 / gemini (v2)](20260508T11_v2-gemini-eq-learn.md)
- [p4 / claude (v2)](20260508T11_v2-claude-rhythm-delay.md)
- [p4 / codex (v2)](20260508T11_v2-codex-rhythm-delay.md)
- [p4 / gemini (v2)](20260508T11_v2-gemini-rhythm-delay.md)
- [p5 / claude (v2)](20260508T11_v2-claude-comb-freeze.md)
- [p5 / codex (v2)](20260508T11_v2-codex-comb-freeze.md)
- [p5 / gemini (v2)](20260508T11_v2-gemini-comb-freeze.md)
