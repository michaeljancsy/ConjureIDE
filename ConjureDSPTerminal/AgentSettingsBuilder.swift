//
//  AgentSettingsBuilder.swift
//  ConjureDSPTerminal
//
//  Builds the `.claude/settings.json` (and accompanying hook scripts) that the
//  embedded agent reads when it's spawned in `agent-workspace/`. Pure
//  Foundation logic — symlinked into ConjureDSPLogicTests so the JSON shape +
//  hook script content can be unit-tested without touching PTYManager.
//
//  The current contents:
//
//  - A PreToolUse hook for Edit / Write / MultiEdit that prints a "did you
//    mean write_bundle_file?" hint when the file_path matches a preset-bundle
//    pattern. Advisory only (always exits 0); the agent can still proceed.
//

import Foundation

enum AgentSettingsBuilder {

    /// Filename for the bundle-path-hint hook script, written next to `settings.json`.
    static let bundlePathHintScriptName = "bundle-path-hint.sh"

    /// Build the JSON that should be written to `<agent-workspace>/.claude/settings.json`.
    ///
    /// `hookScriptAbsolutePath` is the absolute path of the bundle-path-hint shell script —
    /// the hook command in settings.json invokes it with `bash <path>`.
    static func settingsJSON(hookScriptAbsolutePath: String) -> [String: Any] {
        let quotedPath = shellQuoteSingle(hookScriptAbsolutePath)
        let command = "/bin/bash \(quotedPath)"
        return [
            "hooks": [
                "PreToolUse": [
                    [
                        "matcher": "Edit|Write|MultiEdit",
                        "hooks": [
                            [
                                "type": "command",
                                "command": command,
                                "timeout": 5,
                            ]
                        ],
                    ]
                ]
            ]
        ]
    }

    /// Build the shell script body for the bundle-path-hint hook.
    ///
    /// The script:
    /// 1. Reads the hook payload (JSON) from stdin.
    /// 2. Extracts `tool_input.file_path` (or `.edits[0].file_path` for MultiEdit).
    /// 3. If the path matches one of the preset-bundle patterns, prints the hint
    ///    to stdout. Either way, exits 0 (advisory — never blocks the call).
    static func bundlePathHintScript() -> String {
        return """
        #!/bin/bash
        # ConjureDSP agent-workspace PreToolUse hook.
        # Advisory hint: when an Edit/Write/MultiEdit tool call lands on a
        # preset-bundle file, suggest mcp__conjuredsp__write_bundle_file instead.
        # Always exits 0 — never blocks the call.

        set -u
        payload=$(cat)

        # Extract file_path from tool_input (works for Edit and Write).
        # Fall back to edits[0].file_path for MultiEdit.
        path=$(printf '%s' "$payload" | /usr/bin/python3 -c '
        import sys, json
        try:
            d = json.load(sys.stdin)
            ti = d.get("tool_input", {}) or {}
            p = ti.get("file_path") or ""
            if not p:
                edits = ti.get("edits") or []
                if isinstance(edits, list) and edits:
                    p = (edits[0] or {}).get("file_path") or ""
            print(p)
        except Exception:
            pass
        ' 2>/dev/null)

        if [ -z "$path" ]; then
            exit 0
        fi

        match=0
        case "$path" in
            */Library/Group\\ Containers/group.com.MichaelJancsy.ConjureDSP/Presets/*) match=1 ;;
            */manifest.json|*/process.py|*/process.rs)                                  match=1 ;;
            */ui/*.html|*/ui/*.css|*/ui/*.js)                                           match=1 ;;
            */ui/assets/*)                                                              match=1 ;;
        esac

        if [ "$match" = "1" ]; then
            printf '[skill] You'\\''re editing a preset-bundle file (%s). Bundle files live in the App Group container. Use `mcp__conjuredsp__write_bundle_file` instead — it routes through the AU'\\''s MCP server and triggers static validation + hot reload.\\n' "$path"
        fi

        exit 0
        """
    }

    /// True if `path` matches one of the bundle-file patterns the hook flags.
    /// Mirrors the `case` block in `bundlePathHintScript()` so unit tests can
    /// validate the matcher without spawning a shell.
    static func isBundleFilePath(_ path: String) -> Bool {
        // App-Group container Presets directory
        if path.contains("/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/") {
            return true
        }
        // Bundle entry/manifest files (basename match)
        let basename = (path as NSString).lastPathComponent
        if basename == "manifest.json" || basename == "process.py" || basename == "process.rs" {
            return true
        }
        // ui/* files
        // Match `*/ui/<name>.{html,css,js}` and `*/ui/assets/*`.
        // We only care about being under a `ui/` segment — split and inspect.
        let components = (path as NSString).pathComponents
        if let uiIdx = components.firstIndex(of: "ui"), uiIdx < components.count - 1 {
            let after = Array(components[(uiIdx + 1)...])
            // ui/assets/<anything>
            if after.first == "assets", after.count >= 2 {
                return true
            }
            // ui/<name>.{html,css,js} — the first segment after ui is a file
            if after.count == 1 {
                let f = after[0]
                if f.hasSuffix(".html") || f.hasSuffix(".css") || f.hasSuffix(".js") {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Internal helpers

    /// Single-quote a path for safe inclusion in a Bash command.
    private static func shellQuoteSingle(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
