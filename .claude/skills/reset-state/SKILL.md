---
name: reset-state
description: Reset ConjureDSP persisted state — terminal/agent prefs, MCP entries, UserDefaults, or everything. Use before re-testing first-run flows.
user_invocable: true
---

# Reset ConjureDSP State

Use this when the user wants to clear persisted state so ConjureDSP behaves like a fresh install (or a specific subset of fresh).

## Step 1: Ask which scope

Use AskUserQuestion with these options — **do not recommend or pre-select**:

- **Terminal only** — agent picker choice, generated workspace files, MCP instance files. Leaves presets, license, UserDefaults alone. Common choice when re-testing the picker / install-prompt / multi-agent flow.
- **Terminal + per-agent MCP entries** — above, plus remove `conjuredsp` from claude/gemini/codex config. Use when verifying the MCP auto-wire-up.
- **Terminal + UserDefaults** — above (without MCP removal), plus host-app/extension preferences (includes license token cache, settings). Use when debugging first-launch UI.
- **Everything (nuclear)** — wipes App Group container AND `~/Library/Application Support/ConjureDSP`. Deletes presets, git history, subscription token, bundled Python runtime. Requires re-running `rust/setup-python.sh` afterward.

Wait for the answer before continuing.

## Step 2: Confirm apps are quit

Before deleting anything, tell the user to quit both `ConjureDSP.app` and `ConjureDSPTerminal.app`. If they're running, the daemon will rewrite files as you delete them. Ask the user to confirm they've quit before proceeding.

Check with:
```bash
pgrep -lf "ConjureDSP\.app|ConjureDSPTerminal" || echo "not running"
```

If anything shows, stop and ask the user to quit.

## Step 3: Run the reset

Use the exact commands below for the chosen scope. Do not improvise paths.

### Terminal only

Terminal/agent state is split between two locations:
- **App Group container** (`~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/`) — `startup-command` and `agent-mode`. Lives here because the sandboxed extension's Settings pane needs to read/write them, and the App Group container is the only path both the daemon and the sandboxed extension can touch.
- **Application Support** (`~/Library/Application Support/ConjureDSP/`) — `agent-workspace/` (CLAUDE.md/GEMINI.md/AGENTS.md), `mcp-instances/`, `mcp-url.txt`. Daemon-only and agent-shell-only; the extension doesn't read them.

The legacy locations of `startup-command`/`agent-mode` in Application Support are cleared too, in case you're resetting after a build that predates the sandbox fix.

```bash
APP_GROUP="$HOME/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP"
APP_SUPPORT="$HOME/Library/Application Support/ConjureDSP"
rm -f  "$APP_GROUP/startup-command"   "$APP_GROUP/agent-mode"
rm -f  "$APP_SUPPORT/startup-command" "$APP_SUPPORT/agent-mode"
rm -rf "$APP_SUPPORT/mcp-instances"   "$APP_SUPPORT/agent-workspace"
rm -f  "$APP_SUPPORT/mcp-url.txt"
```

### Terminal + per-agent MCP entries
Run the Terminal-only block above, then:
```bash
claude mcp remove conjuredsp 2>/dev/null || true
gemini mcp remove conjuredsp 2>/dev/null || true
codex mcp remove conjuredsp 2>/dev/null || true
```

### Terminal + UserDefaults
Run the Terminal-only block above, then:
```bash
for bid in \
  com.MichaelJancsy.ConjureDSP \
  com.MichaelJancsy.ConjureDSP.debug \
  com.MichaelJancsy.ConjureDSP.ConjureDSPExtension \
  com.MichaelJancsy.ConjureDSP.debug.ConjureDSPExtension; do
  defaults delete "$bid" 2>/dev/null || true
done
```

### Everything (nuclear)
```bash
rm -rf "$HOME/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP"
rm -rf "$HOME/Library/Application Support/ConjureDSP"
```
After this, remind the user they'll need to re-run `rust/setup-python.sh` before the next build (bundled Python lives under Application Support). This also wipes presets, git history, export registry, subscription token.

## Step 4: Report what was cleared

List the paths that actually existed and were removed (check with `ls` before running each `rm` and note which ones were present). Do not claim to have cleared things that weren't there.

Tell the user they can now relaunch to exercise the fresh-install path.
