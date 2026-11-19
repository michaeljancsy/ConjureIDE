---
name: reset-state
description: Reset ConjureIDE's saved state (terminal and agent settings, MCP entries, preferences, or all ConjureIDE data) so it behaves like a fresh install. Use before re-testing first-run flows.
user_invocable: true
---

# Reset ConjureIDE state

`~/Library/Application Support/ConjureDSP/` is shared with other Conjure products (ConjureAlign, ConjureGroove, ConjureWidth keep their settings there). Never delete that whole folder. Delete only the ConjureIDE items named below.

## Step 1: Ask which scope

Ask with AskUserQuestion. Don't recommend one.

- **Terminal only**: agent choice, startup command, generated agent workspace, MCP instance files. Leaves presets and preferences.
- **Terminal + MCP entries**: the above, plus removes `conjuredsp` from the claude, gemini and codex MCP configs.
- **Terminal + preferences**: Terminal only, plus the app's and extension's UserDefaults.
- **All ConjureIDE data**: everything in the App Group container (presets and their git history, Python runtime, compiled WASM cache, export registry) plus ConjureIDE's items in Application Support. Cannot be undone.

## Step 2: Make sure the apps are closed

```bash
pgrep -lf "ConjureDSP\.app|ConjureDSPTerminal" || echo "not running"
```
If anything is running, ask the user to quit `ConjureDSP.app` and `ConjureDSPTerminal.app`, and wait. Otherwise the companion rewrites files as you delete them.

## Step 3: Delete

Before each `rm`, `ls` the path and note whether it existed.

```bash
APP_GROUP="$HOME/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP"
APP_SUPPORT="$HOME/Library/Application Support/ConjureDSP"
```

**Terminal only**
```bash
rm -f  "$APP_GROUP/startup-command" "$APP_GROUP/agent-mode"
rm -r  "$APP_GROUP/mcp-instances"
rm -f  "$APP_SUPPORT/startup-command" "$APP_SUPPORT/agent-mode" "$APP_SUPPORT/mcp-url.txt"
rm -r  "$APP_SUPPORT/mcp-instances" "$APP_SUPPORT/agent-workspace"
```
(The Application Support copies of `startup-command`, `agent-mode` and `mcp-instances` are from older builds.)

**Terminal + MCP entries**: Terminal only, then
```bash
claude mcp remove conjuredsp 2>/dev/null || true
gemini mcp remove conjuredsp 2>/dev/null || true
codex mcp remove conjuredsp 2>/dev/null || true
```

**Terminal + preferences**: Terminal only, then
```bash
for bid in com.MichaelJancsy.ConjureDSP com.MichaelJancsy.ConjureDSP.debug \
  com.MichaelJancsy.ConjureDSP.ConjureDSPExtension com.MichaelJancsy.ConjureDSP.debug.ConjureDSPExtension; do
  defaults delete "$bid" 2>/dev/null || true
done
```

**All ConjureIDE data**: confirm once more with the user (presets and their history are lost), then
```bash
rm -r "$APP_GROUP"
cd "$APP_SUPPORT" && rm -r agent-workspace mcp-instances Exports PythonRuntime PythonRuntime-3.14 rustc-dist uv \
  claude-context.md mcp-url.txt pty-diag.txt terminal-server-port 2>/dev/null
```
Leave `ConjureAlign/`, `ConjureGroove/`, `ConjureWidth/` and any other product folder alone. The Terminal companion reinstalls the Python runtime on its next launch.

## Step 4: Report

List the paths that existed and were removed. Don't claim to have cleared anything that wasn't there. Tell the user they can relaunch to test the fresh-install path.
