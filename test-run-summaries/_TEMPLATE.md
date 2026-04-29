---
date: 2026-04-29T16:17:00-07:00
prompt: "make something with the oscilloscope"
outcome: success                    # success | partial | failed
agent_harness: claude-code          # claude-code | gemini-cli | codex | etc.
agent_model: claude-sonnet-4-6      # specific model the harness ran (3rd-party-via-claude-code is fine)
build_commit: 3eed044               # `git rev-parse --short HEAD` of conjuredsp-application at run time
preset_name: Saturoscope
preset_path: ~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/Saturoscope.cdp
language: rust                      # rust | python
params: [Drive, Mix]                # just names; sizes/units in the body if relevant
turns: 20
duration_seconds: 174
cost_usd: 0.51
tool_errors: 0
tool_calls:                         # mcp__conjuredsp__* only; harness built-ins (TodoWrite, ToolSearch) are noise
  get_docs: 3
  get_script: 1
  save_preset: 1
  read_bundle_file: 1
  write_bundle_file: 2
  smoke_test_ui: 1
log_file: /var/folders/.../conjuredsp-tryit-log-XXXXXX.jsonl
---

## Design

One paragraph. What did the subagent actually build? DSP idea + how the scope is used.
Goal: a future reader skimming summaries can spot patterns (e.g. "5 of 7 'oscilloscope'
runs landed on a saturator").

## What worked

- Bullets. Concrete things — tool flows, validator catches, naming conventions that resolved.
- Skip vague stuff like "agent reasoned well."

## Errors + recoveries

- Each error: one line. What failed, what the recovery was, whether it required a doc lookup.
- Empty section if clean.

## Friction findings

Each finding is one line with a category tag in brackets, then a one-liner. The category
makes cross-run aggregation cheap (`grep '\[docs\]' test-run-summaries/*.md`).

Categories:
- `[docs]` — wording, examples, or coverage in `get_docs(...)` / CLAUDE.md
- `[ux]` — tool descriptions, response messages, validator feedback shape
- `[scaffold]` — what `save_preset(scaffold_ui=true)` emits or omits
- `[bug]` — actual broken behavior
- `[skill]` — friction in `/try-it` itself (port poll, build, dispatch)
- `[meta]` — observation about agent behavior worth noting (e.g. "all runs converged on X")

Examples:
- [scaffold] `save_preset(scaffold_ui=true)` doesn't mirror `params!{}` into manifest.params.
- [ux] `smoke_test_ui` pass message doesn't note that scope/meter UIs need live audio.
- [docs] CLAUDE.md `db_to_gain(ctx.param(X) as f64) as f32` doesn't compile clean — `ctx.param` returns f32.
- [meta] Both runs of "make something with oscilloscope" landed on a tanh saturator.

## Filed?

For each finding, mark whether it was filed as an Asana ticket and link if so. Skip the
section entirely if nothing was filed.

- [scaffold] params block in scaffold → filed as [Asana task title](https://...)
- [meta] both runs picked saturator → not filed (observation only)
