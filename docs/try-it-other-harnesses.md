# try-it: Codex and Gemini comparison runs

Moved from `.claude/skills/try-it/SKILL.md`. `$WORKSPACE`, `$MCP_PORT`, `$SUBAGENT_PROMPT` and `$LOG` are set up as in that skill.

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

**Gemini** — has one pitfall plus a dispatch recipe.

1. **MCP URL is read from a persistent project-scope config** (`gemini mcp add` writes `<cwd>/.gemini/settings.json` — project scope is the default), not a per-call flag. If the AU was rebuilt since the config was last set, the URL is stale and the agent silently sees zero MCP tools — it'll then fall back to shell-curl probes or just give up. **Always refresh immediately before every gemini invocation, from `$WORKSPACE` so the project-scope file the dispatched subprocess will read is the one we write:**

   ```bash
   ( cd "$WORKSPACE" && gemini mcp remove conjuredsp 2>/dev/null )
   ( cd "$WORKSPACE" && gemini mcp add --scope project --transport http conjuredsp "http://localhost:$MCP_PORT/mcp" )
   WORKSPACE="$WORKSPACE" MCP_PORT="$MCP_PORT" python3 -c 'import json,os; d=json.load(open(os.environ["WORKSPACE"]+"/.gemini/settings.json")); url=d.get("mcpServers",{}).get("conjuredsp",{}).get("url",""); assert ":"+os.environ["MCP_PORT"]+"/" in url, f"settings.json url={url!r} does not contain port {os.environ[\"MCP_PORT\"]}"' \
     || { echo "[try-it] $WORKSPACE/.gemini/settings.json missing conjuredsp:$MCP_PORT — gemini config refresh wrote the wrong file." >&2; exit 1; }
   ```

   `--scope project` is the default but stating it documents intent. The python3 parse is robust to multi-server settings.json (won't false-match if another server uses the same port) and to prettifier reformatting.

2. **Dispatch once, then read the log and reason.** Don't pre-match error strings — the dispatching agent has full reasoning surface; any fixed pattern misses errors no one anticipated. Re-run Item 1's MCP refresh before each dispatch (including retries — `$MCP_PORT` can shift between attempts). Use a per-attempt log filename so retried attempts don't overwrite earlier ones:

   ```bash
   MODEL=gemini-2.5-pro   # initial tier; fall back to flash / flash-lite if pro errors
   LOG=/tmp/conjuredsp-tryit-${MODEL}.jsonl
   ( cd "$WORKSPACE" && gemini --yolo -m "$MODEL" \
       --output-format stream-json -p "$SUBAGENT_PROMPT" < /dev/null ) > "$LOG" 2>&1
   ```

   **Always pipe `< /dev/null`** — same reason as codex.

   The last JSON line in `$LOG` is the `result` event: `status` ("success" / "error"), `stats.tool_calls`, and on error `error.message`. Read it and decide. Common patterns the dispatching agent should know:

   - **Quota / capacity errors** ("exhausted your capacity", "No capacity available for model X on the server", `code: 429`) → retry a smaller tier (pro → flash → flash-lite), tell the user briefly.
   - **Success with `tool_calls == 0`** → almost always means the MCP server wasn't reachable; surface to the user, don't trust the digest.
   - **Mid-run error (`tool_calls > 0`)** → the run made progress before failing; surface the partial digest and let the user choose between salvaging, retrying, or stopping.
   - **Anything else** → surface to the user and ask.

   These are starting points, not an exhaustive tree. Read the actual log and reason.

   Record the model(s) actually used in the per-run summary's `agent_model`, joined with `→` if a fallback fired: `gemini-2.5-pro→gemini-2.5-flash-lite (server capacity)`, or `gemini-2.5-pro→gemini-2.5-flash→gemini-2.5-flash-lite (server-capacity fallback chain)`. No `[skill]` friction note for fallbacks that worked — they're upstream, not skill issues.

   **Don't** set `--allowed-mcp-server-names conjuredsp` — that flag has inverted semantics in some gemini-cli builds and silently hides the configured server from the model. Leave the global allowlist alone.

   **Exit behavior of the python3 verify.** If the verification fails, the script calls `exit 1`. Because the `gemini mcp` commands and the verification run at the OUTER script level (NOT inside the `( cd "$WORKSPACE" && gemini ... )` dispatch subshell), `exit 1` terminates the entire `/try-it` invocation — not just the gemini step. `/try-it` is single-harness-per-invocation today (one prompt, one harness, one preset). If multi-harness sweeps are ever added inside the skill, this needs to become a `return` from a harness-scoped function. For now, whole-skill exit is the desired behavior — fail loudly and cheaply instead of burning a 600+ s gemini dispatch on a misconfigured settings.json.

   **Alternative (sidestep `gemini mcp` entirely).** Write `$WORKSPACE/.gemini/settings.json` directly with a heredoc, mirroring the claude `--mcp-config $MCP_CONFIG` pattern. **Caution:** write only `$WORKSPACE/.gemini/settings.json`, NEVER `~/.gemini/settings.json` — the user-scope file holds `security.auth.selectedType` and `ui.errorVerbosity`, and a heredoc would clobber auth config. If you ever need to touch user scope, use `jq` or `python3 -c '...'` for in-place key updates.
