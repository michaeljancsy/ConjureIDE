---
name: try-it
description: Build, launch, and dispatch a fresh `claude -p` subprocess that authors a ConjureDSP preset via the running AU's MCP server — for quick experimental cycles to see how embedded-agent guidance + MCP tooling holds up against a new prompt.
user_invocable: true
---

# Try It

Replicates the live-experiment flow used to validate embedded-agent guidance + MCP tool surface area:

1. Build + launch the ConjureDSP host app.
2. Wait for the AU's MCP server to come up.
3. Spawn a **fresh subagent subprocess** from `agent-workspace/` with the MCP server pre-wired (subagent uses ConjureDSP MCP tools natively).
4. Feed the user's prompt to that subprocess and capture its tool-call timeline + final report.
5. Show the report.
6. Write a structured per-run summary to `test-run-summaries/` and offer to file findings as Asana tickets.

Use this whenever you want to validate that a fresh agent (no shared context with this conversation) can productively author a preset using the documented tools and guidance. Friction is the signal — most outcomes turn into backlog tickets, and the per-run summary builds an aggregable record across many invocations.

## Step 1: Get the prompt

If `args` is non-empty, treat it as the user's prompt verbatim (e.g. "build a 3-band dynamic EQ", "vintage tape saturation", "an XY-pad-controlled multi-tap delay").

If `args` is empty, ask with AskUserQuestion: "What should the subagent build?" Wait for the answer.

## Step 2: Build + launch (Debug + Beta — don't ask)

The experimental cycle benefits from the fastest rebuild AND full licensing without demo-timer interruptions. Hard-code Debug + Beta — don't ask.

```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Debug build \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG BETA_BUILD' 2>&1 | tail -60
```

Use a 600000 ms (10 min) timeout — Rust rebuilds can be slow on a clean build.

If the build fails (look for `error:` in the output), surface the error to the user and stop. Do not try to launch.

After a successful build, resolve the build-products path and launch:

```bash
BUILT_PRODUCTS_DIR=$(xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR / {print $3; exit}')
APP_PATH="$BUILT_PRODUCTS_DIR/ConjureDSP.app"
test -d "$APP_PATH" && open "$APP_PATH"
```

## Step 3: Wait for the AU's MCP server

The AU extension writes a JSON file per running instance to:

```
~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/mcp-instances/<uuid>.json
```

Each file has `{ "mcpPort": <UInt16>, "pid": <Int32>, "createdAt": <epoch>, ... }`. The host app loads the AU automatically on launch, so the file should appear within a few seconds.

Poll up to 30 seconds, picking the most recent file:

```bash
INSTANCES_DIR="$HOME/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/mcp-instances"
MCP_PORT=""
for i in $(seq 1 30); do
  newest=$(ls -t "$INSTANCES_DIR"/*.json 2>/dev/null | head -1)
  if [ -n "$newest" ]; then
    MCP_PORT=$(python3 -c "import json,sys; d=json.load(open('$newest')); print(d.get('mcpPort',''))" 2>/dev/null)
    if [ -n "$MCP_PORT" ] && [ "$MCP_PORT" != "0" ]; then break; fi
  fi
  sleep 1
done
echo "MCP_PORT=$MCP_PORT"
```

If after 30 seconds no port surfaces, surface the issue to the user (likely: AU didn't load, host app crashed, App Group container has stale instance files from a prior run). Tell the user to check Console.app for `[MCPServer]` logs and stop.

If multiple instance files exist (rare — happens if the host app + a DAW are both running ConjureDSP), pick the newest by mtime as `ls -t` does.

## Step 4: Verify agent-workspace context

The subprocess needs the embedded-agent context (the system prompt the in-plugin Claude Code session sees, written from `PTYManager.contextContent`). That lives at:

```
~/Library/Application Support/ConjureDSP/agent-workspace/{AGENTS.md, CLAUDE.md, GEMINI.md}
```

It gets (re)written every time `PTYManager.start()` runs — i.e. every time the user opens the terminal pane in the AU UI.

```bash
WORKSPACE="$HOME/Library/Application Support/ConjureDSP/agent-workspace"
test -f "$WORKSPACE/AGENTS.md" || { echo "NO_WORKSPACE"; }
```

If `AGENTS.md` is missing, tell the user: "Open the terminal pane in the AU once (it triggers `writeAgentWorkspace()`), then re-run `/try-it`." Stop — don't proceed without the context, otherwise the subagent runs with this repo's developer-facing AGENTS.md instead and gets the wrong persona.

The content can be slightly stale relative to the running host app if the user has been editing `PTYManager.contextContent` mid-session — that's accepted; for tighter sync the user opens the terminal pane.

## Step 5: Write a temp MCP config + dispatch the subprocess

Generate the temp MCP config:

```bash
MCP_CONFIG=$(mktemp -t conjuredsp-tryit-XXXXXX.json)
cat > "$MCP_CONFIG" <<EOF
{
  "mcpServers": {
    "conjuredsp": {
      "type": "http",
      "url": "http://localhost:$MCP_PORT/mcp"
    }
  }
}
EOF
```

Compose the subagent prompt — keep it minimal, since the agent-workspace AGENTS.md already covers tool usage + workflow. The prompt is mostly the user's request plus a debrief instruction:

```
SUBAGENT_PROMPT=$(cat <<'PROMPT'
Build the following ConjureDSP plugin via the conjuredsp MCP server:

  <USER_PROMPT_VERBATIM>

When you're done (or if you give up), reply with a short markdown digest:

  - What you built: preset name, language, parameter list, brief design summary.
  - What worked smoothly.
  - Any errors you hit and how you recovered.
  - Anything that felt like a tooling, doc, or guidance gap.

The last bullet matters most — friction is the signal. If the docs misled you,
if a tool error message was confusing, if the API didn't expose something you
needed, say so explicitly.
PROMPT
)
# (substitute <USER_PROMPT_VERBATIM> with the user's args using the shell, NOT a literal heredoc-replace, to avoid quoting traps)
```

Run the subprocess from `$WORKSPACE`:

```bash
LOG=$(mktemp -t conjuredsp-tryit-log-XXXXXX.jsonl)
( cd "$WORKSPACE" && claude -p "$SUBAGENT_PROMPT" \
    --mcp-config "$MCP_CONFIG" \
    --strict-mcp-config \
    --output-format stream-json \
    --verbose \
    --include-partial-messages \
    --no-session-persistence \
    --permission-mode bypassPermissions \
  ) > "$LOG" 2>&1
echo "Subagent log: $LOG"
```

Flag rationale:

- `--mcp-config` + `--strict-mcp-config`: only the conjuredsp MCP is loaded for this subprocess. No leakage from user/project MCP config.
- `--output-format stream-json --verbose --include-partial-messages`: emits one JSONL event per turn / tool call / message → tool-call timeline for the debrief.
- `--no-session-persistence`: don't pollute the user's `/resume` picker with experimental sessions.
- `--permission-mode bypassPermissions`: subagent runs autonomously with no per-tool approval prompts. **This is intentional for the experimental cycle** — we want to see what the agent does unchaperoned. Mention this when summarizing to the user.

Don't set a timeout on the Bash call shorter than ~10 min — the subagent does real work (Rust compile takes a few seconds, smoke_test_ui can take a few seconds, multi-step iterations add up). 600000 ms is fine.

### Multi-harness sweeps (codex / gemini)

The default dispatch above is `claude -p`. When the user asks for a multi-harness comparison sweep (e.g. "5 prompts × 3 providers"), use these CLIs for the other two harnesses. **All three must run sequentially** — the AU's MCP server is single-tenant and `compile_and_run` mutates global kernel state, so concurrent harnesses clobber each other.

**Codex** — MCP URL passes inline via `-c`, so no global config writes. Always pipe `< /dev/null` to stdin or codex hangs waiting for additional input even when a prompt is provided as an argument.

```bash
( cd "$WORKSPACE" && codex exec \
    --skip-git-repo-check \
    --dangerously-bypass-approvals-and-sandbox \
    --json \
    -c "mcp_servers.conjuredsp.url=\"http://localhost:$MCP_PORT/mcp\"" \
    "$SUBAGENT_PROMPT" \
  < /dev/null ) > "$LOG" 2>&1
```

Codex emits `{"type":"turn.completed", "usage":{...}}` and `{"type":"item.completed", "item":{"type":"agent_message", "text":...}}` events. The CLI does **not** report a per-run USD cost — capture `usage.input_tokens` / `usage.output_tokens` instead and leave `cost_usd: n/a` in the summary frontmatter.

**Gemini** — has two pitfalls.

1. **MCP URL is read from a persistent project-scope config** (`gemini mcp add` writes `<cwd>/.gemini/settings.json` — project scope is the default), not a per-call flag. If the AU was rebuilt since the config was last set, the URL is stale and the agent silently sees zero MCP tools — it'll then fall back to shell-curl probes or just give up. **Always refresh immediately before every gemini invocation, from `$WORKSPACE` so the project-scope file the dispatched subprocess will read is the one we write:**

   ```bash
   ( cd "$WORKSPACE" && gemini mcp remove conjuredsp 2>/dev/null )
   ( cd "$WORKSPACE" && gemini mcp add --scope project --transport http conjuredsp "http://localhost:$MCP_PORT/mcp" )
   WORKSPACE="$WORKSPACE" MCP_PORT="$MCP_PORT" python3 -c 'import json,os; d=json.load(open(os.environ["WORKSPACE"]+"/.gemini/settings.json")); url=d.get("mcpServers",{}).get("conjuredsp",{}).get("url",""); assert ":"+os.environ["MCP_PORT"]+"/" in url, f"settings.json url={url!r} does not contain port {os.environ[\"MCP_PORT\"]}"' \
     || { echo "[try-it] $WORKSPACE/.gemini/settings.json missing conjuredsp:$MCP_PORT — gemini config refresh wrote the wrong file." >&2; exit 1; }
   ```

   `--scope project` is the default but stating it documents intent. The python3 parse is robust to multi-server settings.json (won't false-match if another server uses the same port) and to prettifier reformatting.

2. **`gemini-2.5-pro` daily quota is tight** — ~2–3 multi-iteration preset-authoring runs and you hit `code: 429, "exhausted your capacity on this model"` with a 12+ hour reset. Detect this in the `result` event (`status:"error"` and `error.message` contains `exhausted`) and **automatically retry the same prompt with `-m gemini-2.5-flash`**. Flash's quota is much more generous and it's still capable enough for most preset tasks.

   Pseudocode for the gemini branch:

   ```bash
   ( cd "$WORKSPACE" && gemini mcp remove conjuredsp 2>/dev/null )
   ( cd "$WORKSPACE" && gemini mcp add --scope project --transport http conjuredsp "http://localhost:$MCP_PORT/mcp" )
   WORKSPACE="$WORKSPACE" MCP_PORT="$MCP_PORT" python3 -c 'import json,os; d=json.load(open(os.environ["WORKSPACE"]+"/.gemini/settings.json")); url=d.get("mcpServers",{}).get("conjuredsp",{}).get("url",""); assert ":"+os.environ["MCP_PORT"]+"/" in url, f"settings.json url={url!r} does not contain port {os.environ[\"MCP_PORT\"]}"' \
     || { echo "[try-it] $WORKSPACE/.gemini/settings.json missing conjuredsp:$MCP_PORT — gemini config refresh wrote the wrong file." >&2; exit 1; }
   MODEL_USED="gemini-2.5-pro"
   ( cd "$WORKSPACE" && gemini --yolo -m "$MODEL_USED" \
       --output-format stream-json -p "$SUBAGENT_PROMPT" < /dev/null ) > "$LOG" 2>&1
   if grep -q '"reason":"QUOTA_EXHAUSTED"\|exhausted your capacity' "$LOG"; then
     MODEL_USED="gemini-2.5-pro→gemini-2.5-flash (quota fallback)"
     ( cd "$WORKSPACE" && gemini --yolo -m gemini-2.5-flash \
         --output-format stream-json -p "$SUBAGENT_PROMPT" < /dev/null ) > "$LOG" 2>&1
   fi
   ```

   **Always pipe `< /dev/null`** — same reason as codex.

   In the per-run summary frontmatter, set `agent_model: <MODEL_USED>` so cross-run aggregation knows the fallback fired. When a fallback happened, also add a `[skill]` line in `## Friction findings`: `gemini-2.5-pro quota exhausted; auto-fell back to gemini-2.5-flash.`

   **Don't** set `--allowed-mcp-server-names conjuredsp` — that flag has inverted semantics in some gemini-cli builds and silently hides the configured server from the model. Leave the global allowlist alone.

   **Exit behavior of the python3 verify.** If the verification fails, the script calls `exit 1`. Because the `gemini mcp` commands and the verification run at the OUTER script level (NOT inside the `( cd "$WORKSPACE" && gemini ... )` dispatch subshell), `exit 1` terminates the entire `/try-it` invocation — not just the gemini step. `/try-it` is single-harness-per-invocation today (one prompt, one harness, one preset). If multi-harness sweeps are ever added inside the skill, this needs to become a `return` from a harness-scoped function. For now, whole-skill exit is the desired behavior — fail loudly and cheaply instead of burning a 600+ s gemini dispatch on a misconfigured settings.json.

   **Alternative (sidestep `gemini mcp` entirely).** Write `$WORKSPACE/.gemini/settings.json` directly with a heredoc, mirroring the claude `--mcp-config $MCP_CONFIG` pattern. **Caution:** write only `$WORKSPACE/.gemini/settings.json`, NEVER `~/.gemini/settings.json` — the user-scope file holds `security.auth.selectedType` and `ui.errorVerbosity`, and a heredoc would clobber auth config. If you ever need to touch user scope, use `jq` or `python3 -c '...'` for in-place key updates.

## Step 6: Surface the report

Read the JSONL log. Extract and show to the user:

- **The final assistant message** — the last `type:"assistant"` event's content. Show this verbatim to the user as the subagent's report.
- **Tool-call timeline** — count of each `mcp__conjuredsp__*` tool call (and any tool errors: events with `is_error: true`). Show as a one-line summary, e.g.:

  > Subagent finished in N turns ($X.XX). Tool calls: get_docs×1, save_preset×1, get_audio_state×1, get_parameters×1, smoke_test_ui×2 (1 fail → 1 pass after fix).
- **Total cost / turns** — from the final `type:"result"` event.

## Step 7: Write a structured summary to `test-run-summaries/`

After surfacing the report, **always** write a per-run summary file. The in-conversation surfacing is ephemeral; this file is the persistent, aggregable record across runs.

Path: `test-run-summaries/` at the project root. Filename: `YYYY-MM-DD-HHMM_<slug>.md`, where `<slug>` is a 1–3 word kebab-case keyword derived from the prompt (e.g. `oscilloscope`, `tape-saturation`, `xy-delay`). Use current local date/time.

Format: follow `test-run-summaries/_TEMPLATE.md` exactly. Fields and where they come from:

**Frontmatter** (extracted programmatically):
- `date`: ISO 8601 with timezone offset, current local time.
- `prompt`: the user's args, verbatim, quoted.
- `outcome`: `success` if `type:"result"` event has `is_error: false` AND a fresh `.cdp` bundle landed in the App Group `Presets/`; `partial` if the subagent gave up but reported usefully; `failed` if the harness errored or no preset was produced.
- `agent_harness`: `claude-code` for the default `claude -p` dispatch. For multi-harness sweeps use `codex-cli` or `gemini-cli`.
- `agent_model`: from the first `type:"system",subtype:"init"` (claude) or `type:"init"` (gemini) event's `model` field. Codex doesn't surface a model field — record `codex-cli` and let the run's `usage` totals carry the signal. **If a gemini quota fallback fired** (Pro 429 → flash retry, see Step 5 multi-harness section), record `agent_model: gemini-2.5-pro→gemini-2.5-flash (quota fallback)` so cross-run aggregation can spot it.
- `build_commit`: `git rev-parse --short HEAD` at run time.
- `preset_name`, `preset_path`: from the subagent's digest (it names what it built); confirm by listing `~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/` for the freshest `.cdp` bundle.
- `language`: `rust` or `python` — read from the bundle's `manifest.json`.
- `params`: list of param names, from `manifest.json`'s `params` array (or the DSP source if v1 schema).
- `turns`, `duration_seconds`, `cost_usd`: from the `type:"result"` event (`num_turns`, `duration_ms / 1000`, `total_cost_usd`).
- `tool_errors`: count of `is_error: true` tool_result events.
- `tool_calls`: object — count each `mcp__conjuredsp__*` tool by stripping the prefix. **Exclude harness built-ins** (`TodoWrite`, `ToolSearch`, `Bash`, `Read`, etc.) — they're noise, not signal about the ConjureDSP MCP surface.
- `log_file`: absolute path to the JSONL log.

**Body** (synthesized from the subagent's digest):
- `## Design` — one paragraph: DSP idea + how the UI / telemetry / scope ties in. Keep it tight enough that a future reader skimming many summaries can spot patterns ("5 of 7 'oscilloscope' runs landed on a saturator").
- `## What worked` — concrete bullets (tool flows, validator catches, naming resolutions). No vague praise.
- `## Errors + recoveries` — one line per error: what failed, what fixed it. Leave empty for clean runs.
- `## Friction findings` — bullets with category tags in brackets, then a one-liner. Categories: `[docs]` (wording / examples / coverage), `[ux]` (tool descriptions, response messages, validator feedback shape), `[scaffold]` (what `save_preset(scaffold_ui=true)` emits or omits), `[bug]` (broken behavior), `[skill]` (friction in `/try-it` itself — port poll, build, dispatch), `[meta]` (observation about agent behavior, e.g. recurring design choices). Tags make cross-run aggregation cheap (`grep '\[scaffold\]' test-run-summaries/*.md`).
- `## Filed?` — leave empty initially; populated in Step 8 as Asana tickets land.

Write the file with the Write tool. Tell the user where it landed using a markdown link.

## Step 8: Offer to file findings as Asana tickets

Ask: "File any findings as Asana tickets in the ConjureDSP Backlog?"

For each finding the user wants filed, create an Asana task in project gid `1214126484601018`, **section `try-it motivated tasks` (gid `1214784911414048`)**. All `/try-it`-spawned tickets land in this one section so the user can see in one place what came out of this experimental flow vs other backlog work — don't fan them out across `Bugs` / `UX` / `Other` by topic.

Title in imperative form, body summarizing the friction. Include a pointer to the log file path so future sessions can reference what the subagent saw. If the body description suggests a topical home (the finding is really a bug vs a docs change vs a UX tweak), record that in the body or title prefix (`Bug:` / `Docs:` / `UX:` / `API:`) rather than via section placement.

After each ticket lands, **edit the summary file's `## Filed?` section** to add a line: `- [tag] one-liner → [Asana task title](url)`. This keeps the persistent record in sync with what's in flight.

## Cleanup

The temp MCP config and log files live in `/tmp` — let the OS clean them up. Don't `rm` them; they're useful if the user wants to re-inspect.

The new preset the subagent saved lives in the user's preset library (App Group container's `Presets/` dir, git-tracked via `PresetGitCoordinator`). Don't auto-commit; the user inspects in the host app's preset browser and decides.

## What NOT to do

- Don't auto-accept the subagent's report — surface it verbatim and let the user decide what to file.
- Don't modify the user's MCP config (`claude mcp add`). The temp config is per-subprocess, scoped to this run.
- Don't retry the subagent automatically if it errors. Surface the error and let the user decide.
- Don't run `/try-it` again immediately to "patch" the subagent's output — each invocation is a fresh experiment with no shared state.
- Don't run from the project root — the dev-facing AGENTS.md gives the wrong persona. Always cd to `agent-workspace/`.
