---
name: try-it
description: Build, launch, and dispatch a fresh `claude -p` subprocess that authors a ConjureDSP preset via the running AU's MCP server — for quick experimental cycles to see how embedded-agent guidance + MCP tooling holds up against a new prompt.
user_invocable: true
---

# Try It

Replicates the live-experiment flow used to validate embedded-agent guidance + MCP tool surface area:

1. Build + launch the ConjureDSP host app.
2. Wait for the AU's MCP server to come up.
3. Spawn a **fresh `claude -p` subprocess** from `agent-workspace/` with the MCP server pre-wired (subagent uses ConjureDSP MCP tools natively).
4. Feed the user's prompt to that subprocess and capture its tool-call timeline + final report.
5. Show the report and offer to file findings as Asana tickets.

Use this whenever you want to validate that a fresh agent (no shared context with this conversation) can productively author a preset using the documented tools and guidance. Friction is the signal — most outcomes turn into backlog tickets.

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

## Step 6: Surface the report + offer to file findings

Read the JSONL log. Extract:

- **The final assistant message** — the last `type:"assistant"` event's content. Show this verbatim to the user as the subagent's report.
- **Tool-call timeline** — count of each `mcp__conjuredsp__*` tool call (and any tool errors: events with `is_error: true`). Show as a one-line summary, e.g.:

  > Subagent finished in N turns ($X.XX). Tool calls: get_docs×1, save_preset×1, get_audio_state×1, get_parameters×1, smoke_test_ui×2 (1 fail → 1 pass after fix).
- **Total cost / turns** — from the final `type:"result"` event.

Then ask: "File any findings from the 'gaps' section as Asana tickets in the ConjureDSP Backlog?"

For each finding the user wants filed, create an Asana task in project gid `1214126484601018`:

- Default section: `Other` (gid `1214134192758345`)
- Use `Bugs` (gid `1214126485669453`) if it's a clear bug
- Use `UX` (gid `1214126485654834`) if it's a UX/copy issue

Title in imperative form, body summarizing the friction. Include a pointer to the log file path so future sessions can reference what the subagent saw.

## Cleanup

The temp MCP config and log files live in `/tmp` — let the OS clean them up. Don't `rm` them; they're useful if the user wants to re-inspect.

The new preset the subagent saved lives in the user's preset library (App Group container's `Presets/` dir, git-tracked via `PresetGitCoordinator`). Don't auto-commit; the user inspects in the host app's preset browser and decides.

## What NOT to do

- Don't auto-accept the subagent's report — surface it verbatim and let the user decide what to file.
- Don't modify the user's MCP config (`claude mcp add`). The temp config is per-subprocess, scoped to this run.
- Don't retry the subagent automatically if it errors. Surface the error and let the user decide.
- Don't run `/try-it` again immediately to "patch" the subagent's output — each invocation is a fresh experiment with no shared state.
- Don't run from the project root — the dev-facing AGENTS.md gives the wrong persona. Always cd to `agent-workspace/`.
