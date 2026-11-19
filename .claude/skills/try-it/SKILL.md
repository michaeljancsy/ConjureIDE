---
name: try-it
description: Build and launch ConjureIDE, then have a fresh `claude -p` run build a preset through the running AU's MCP server — a quick experiment to see how the in-app agent's instructions and MCP tools hold up against a new prompt.
user_invocable: true
---

# Try it

Builds and launches the app, starts a fresh agent in the in-app agent's workspace with only the ConjureIDE MCP server, gives it the user's prompt, shows its report, and saves a summary to `test-run-summaries/`. Friction in the run is the point: most findings become GitHub issues.

The app opens windows, so claim a screen turn first (`screen-turn status`, then `screen-turn claim --who "<your session title>" --minutes 30 --what "ConjureIDE try-it run"`), and release it when done.

## Step 1: The prompt

Use `args` verbatim, or ask "What should the agent build?".

## Step 2: Build and launch (Debug, don't ask)

Run in the background (Rust builds can take minutes):
```bash
xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Debug build
```
If it fails, show the `error:` lines and stop. Otherwise:
```bash
BUILT_PRODUCTS_DIR=$(xcodebuild -project ConjureDSP.xcodeproj -scheme ConjureDSP -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR / {print $3; exit}')
test -d "$BUILT_PRODUCTS_DIR/ConjureDSP.app" && open "$BUILT_PRODUCTS_DIR/ConjureDSP.app"
```

## Step 3: Wait for the MCP port (up to 30 s)

```bash
INSTANCES_DIR="$HOME/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/mcp-instances"
MCP_PORT=""
for i in $(seq 1 30); do
  newest=$(ls -t "$INSTANCES_DIR"/*.json 2>/dev/null | head -1)
  [ -n "$newest" ] && MCP_PORT=$(python3 -c "import json; print(json.load(open('$newest')).get('mcpPort',''))" 2>/dev/null)
  [ -n "$MCP_PORT" ] && [ "$MCP_PORT" != "0" ] && break
  sleep 1
done; echo "MCP_PORT=$MCP_PORT"
```
No port after 30 s: tell the user (AU didn't load, app crashed, or stale instance files) and stop.

## Step 4: Check the agent workspace

```bash
WORKSPACE="$HOME/Library/Application Support/ConjureDSP/agent-workspace"
test -f "$WORKSPACE/AGENTS.md" || echo "NO_WORKSPACE"
```
If missing: "Open the terminal pane in the AU once, then re-run /try-it." Always run the agent from `$WORKSPACE`, never from the repo (the repo's AGENTS.md is for developers).
Note: Claude Code's saved memory for that folder (`~/.claude/projects/-Users-michaeljancsy-Library-Application-Support-ConjureDSP-agent-workspace/memory/`) also loads, so the run is not fully fresh. Mention this in the summary.

## Step 5: Run the agent

```bash
MCP_CONFIG=$(mktemp -t conjuredsp-tryit-XXXXXX.json)
printf '{"mcpServers":{"conjuredsp":{"type":"http","url":"http://localhost:%s/mcp"}}}' "$MCP_PORT" > "$MCP_CONFIG"
LOG=$(mktemp -t conjuredsp-tryit-log-XXXXXX.jsonl)
( cd "$WORKSPACE" && claude -p "$SUBAGENT_PROMPT" --mcp-config "$MCP_CONFIG" --strict-mcp-config \
    --output-format stream-json --verbose --include-partial-messages --no-session-persistence \
    --permission-mode bypassPermissions --disallowedTools Bash ) > "$LOG" 2>&1
```
`$SUBAGENT_PROMPT` is: "Build the following ConjureDSP plugin via the conjuredsp MCP server: <prompt>. When done (or if you give up), reply with a short digest: what you built (name, language, parameters, design), what worked, errors and how you recovered, and any tooling, doc or guidance gaps. The last point matters most." Insert the prompt with shell variables, not by editing a heredoc.

`bypassPermissions` lets the agent run unattended with no approval prompts. `--disallowedTools Bash` takes away its command-line access, so it can only work through the MCP server and file tools. Run in the background with a timeout of at least 10 minutes.

Codex and Gemini comparison runs: see `docs/try-it-other-harnesses.md`. Run harnesses one at a time; the MCP server is single-tenant.

## Step 6: Show the report

From the log: the last assistant message (verbatim), a one-line count of each `mcp__conjuredsp__*` call and any `is_error: true` results, and turns, time and cost from the `result` event.

## Step 7: Save a summary

Write `test-run-summaries/YYYY-MM-DD-HHMM_<slug>.md` following `test-run-summaries/_TEMPLATE.md` exactly. Count only `mcp__conjuredsp__*` tools in `tool_calls`. `outcome` is `success` only if the result has `is_error: false` and a new `.cdp` appeared in the App Group `Presets/` folder. Tag friction bullets `[docs]`, `[ux]`, `[scaffold]`, `[bug]`, `[skill]` or `[meta]`.

## Step 8: Offer to file issues

Ask "File any findings as GitHub issues?". For each yes: `gh issue create --label try-it`, title prefixed `Bug:`, `Docs:`, `UX:` or `API:`, body with the friction and the log path. Add each issue link under `## Filed?` in the summary.

## Afterwards

Leave the temp files and the new preset alone; don't commit the preset. Quit the app if you launched it, and release the screen turn.
Don't add the MCP server to the user's config, don't retry unfamiliar errors, and don't re-run to "patch" a result.
