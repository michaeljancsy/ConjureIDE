---
title: Three-harness sweep — claude / codex / gemini × 5 STATE-channel prompts
date: 2026-05-08T00:15:00-07:00
build_commit: d6061ec
sweep_total_runs: 15
---

# Three-harness friction comparison

5 prompts, all designed to lean on the recently-shipped STATE channel + custom UI surface.
Each prompt run on three CLI agent harnesses with the conjuredsp MCP server pre-wired:
**Claude Code (`claude -p`)**, **Codex CLI (`codex exec --json`)**, **Gemini CLI
(`gemini -p --output-format stream-json`)** with model `gemini-2.5-pro`. Each run was
non-interactive, fully-permissive (`bypassPermissions` / `--dangerously-bypass-approvals-and-sandbox`
/ `--yolo`), with no MCP-config leakage from the host. Agent-workspace `AGENTS.md` was the
shared context; the prompt was the *only* per-run input.

## Results

| Prompt | Harness | Outcome | Turns | Wall (s) | Cost | Preset bundle |
|---|---|---|---:|---:|---:|---|
| p1 | claude | success | 11 | 146 | $0.87 | Step Gate 16.cdp |
| p1 | codex | success | 1 | 0 | — | 16-Step Gate Sequencer.cdp |
| p1 | gemini | success | 17 | 100 | — | Step Sequencer.cdp |
| p2 | claude | success | 9 | 129 | $1.00 | A_B Saturator.cdp |
| p2 | codex | success | 1 | 0 | — | Snapshot Saturator.cdp |
| p2 | gemini | partial | 30 | 290 | — | — |
| p3 | claude | success | 18 | 372 | $1.20 | Learn EQ.cdp |
| p3 | codex | success | 1 | 0 | — | EQ4Learn.cdp |
| p3 | gemini | partial | 32 | 292 | — | — |
| p4 | claude | success | 17 | 186 | $1.21 | Rhythmic Step Delay.cdp |
| p4 | codex | success | 1 | 0 | — | RhythmicSteps.cdp |
| p4 | gemini | partial | 36 | 495 | — | — |
| p5 | claude | success | 34 | 362 | $2.12 | Spectral Freeze Comb.cdp |
| p5 | codex | success | 1 | 0 | — | Spectral Freeze Comb Resonator.cdp |
| p5 | gemini | success | 17 | 186 | — | SpectralResonator_rust.cdp |

## Aggregate per harness

| Harness | Runs | Success | Total cost (where reported) |
|---|---:|---:|---:|
| claude | 5 | 5/5 | $6.41 |
| codex | 5 | 5/5 | (not reported) |
| gemini | 5 | 2/5 | (not reported) |

## Per-run summary files

- [p1 / claude](2026-05-07-1842_claude-gate-seq.md)
- [p1 / codex](2026-05-07-2325_codex-gate-seq.md)
- [p1 / gemini](2026-05-07-2327_gemini-gate-seq.md)
- [p2 / claude](2026-05-07-2328_claude-ab-snapshot.md)
- [p2 / codex](2026-05-07-2330_codex-ab-snapshot.md)
- [p2 / gemini](2026-05-07-2331_gemini-ab-snapshot.md)
- [p3 / claude](2026-05-07-2336_claude-eq-learn.md)
- [p3 / codex](2026-05-07-2342_codex-eq-learn.md)
- [p3 / gemini](2026-05-07-2345_gemini-eq-learn.md)
- [p4 / claude](2026-05-07-2349_claude-rhythm-delay.md)
- [p4 / codex](2026-05-07-2353_codex-rhythm-delay.md)
- [p4 / gemini](2026-05-07-2355_gemini-rhythm-delay.md)
- [p5 / claude](2026-05-08-0003_claude-comb-freeze.md)
- [p5 / codex](2026-05-08-0009_codex-comb-freeze.md)
- [p5 / gemini](2026-05-08-0011_gemini-comb-freeze.md)
