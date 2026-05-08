//
//  AgentSettingsBuilderTests.swift
//  ConjureDSPLogicTests
//
//  Unit tests for AgentSettingsBuilder — the JSON shape PTYManager writes to
//  `<agent-workspace>/.claude/settings.json`, the accompanying hook script
//  body, and the path-matching predicate that mirrors the script's `case`.
//
//  We test:
//    1. settingsJSON shape — registers a PreToolUse hook for Edit|Write|MultiEdit
//       and points at the supplied script path.
//    2. JSON survives round-trip through JSONSerialization (so PTYManager's
//       writer can serialize it cleanly).
//    3. bundlePathHintScript() runs as a real shell script and prints the
//       expected hint for matching paths, prints nothing for non-matching
//       paths, and always exits 0.
//    4. isBundleFilePath() Swift-level matcher mirrors the script's case
//       block — covers all the bundle patterns from the spec.
//

import Foundation
import Testing

@Suite struct AgentSettingsBuilderTests {

    // MARK: - settingsJSON shape

    @Test("settingsJSON contains a PreToolUse hook matching Edit|Write|MultiEdit")
    func settingsJSONShape() throws {
        let scriptPath = "/tmp/foo/bundle-path-hint.sh"
        let dict = AgentSettingsBuilder.settingsJSON(hookScriptAbsolutePath: scriptPath)

        // Top-level key
        let hooks = try #require(dict["hooks"] as? [String: Any], "Expected top-level \"hooks\" object")
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]], "Expected hooks.PreToolUse array")
        #expect(preToolUse.count == 1, "Expected exactly one PreToolUse entry")

        let entry = preToolUse[0]
        #expect(entry["matcher"] as? String == "Edit|Write|MultiEdit")

        let inner = try #require(entry["hooks"] as? [[String: Any]])
        #expect(inner.count == 1)

        let hook = inner[0]
        #expect(hook["type"] as? String == "command")

        let command = try #require(hook["command"] as? String)
        #expect(command.contains("/bin/bash"))
        #expect(command.contains(scriptPath))
    }

    @Test("settingsJSON survives JSONSerialization round-trip")
    func settingsJSONRoundTrip() throws {
        let scriptPath = "/Users/test/agent-workspace/.claude/hooks/bundle-path-hint.sh"
        let dict = AgentSettingsBuilder.settingsJSON(hookScriptAbsolutePath: scriptPath)

        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded != nil, "Round-tripped JSON should decode back to a dict")

        let hooks = decoded?["hooks"] as? [String: Any]
        let preToolUse = hooks?["PreToolUse"] as? [[String: Any]]
        #expect(preToolUse?.first?["matcher"] as? String == "Edit|Write|MultiEdit")
    }

    @Test("settingsJSON quotes script paths with shell-significant chars safely")
    func settingsJSONQuotesPathsWithSpaces() throws {
        let scriptPath = "/Users/Alice O'Donnell/Application Support/agent-workspace/.claude/hooks/bundle-path-hint.sh"
        let dict = AgentSettingsBuilder.settingsJSON(hookScriptAbsolutePath: scriptPath)

        let hooks = dict["hooks"] as? [String: Any]
        let preToolUse = hooks?["PreToolUse"] as? [[String: Any]]
        let entry = try #require(preToolUse?[0])
        let inner = entry["hooks"] as? [[String: Any]]
        let command = try #require(inner?[0]["command"] as? String)

        // The path should be present and the apostrophe should be properly
        // escaped for single-quote shell context (i.e. the command must not
        // contain a raw `'` that breaks out of the surrounding quotes).
        #expect(command.contains("Alice O"))
        // The whole command should be parseable by `bash -n` (syntax check).
        let process = Process()
        process.launchPath = "/bin/bash"
        process.arguments = ["-n", "-c", command]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "bash -n rejected the hook command: \(errText)")
    }

    // MARK: - isBundleFilePath matcher

    @Test("isBundleFilePath flags App-Group Presets directory paths")
    func matchesPresetsDirectory() {
        let p = "/Users/me/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/MyPreset.cdp/anything.txt"
        #expect(AgentSettingsBuilder.isBundleFilePath(p))
    }

    @Test("isBundleFilePath flags manifest.json by basename")
    func matchesManifest() {
        #expect(AgentSettingsBuilder.isBundleFilePath("/some/random/path/manifest.json"))
        #expect(AgentSettingsBuilder.isBundleFilePath("/Presets/Foo.cdp/manifest.json"))
    }

    @Test("isBundleFilePath flags process.py and process.rs")
    func matchesProcessEntryFiles() {
        #expect(AgentSettingsBuilder.isBundleFilePath("/foo/bar/process.py"))
        #expect(AgentSettingsBuilder.isBundleFilePath("/foo/bar/process.rs"))
    }

    @Test("isBundleFilePath flags ui/*.html, ui/*.css, ui/*.js")
    func matchesUIFiles() {
        #expect(AgentSettingsBuilder.isBundleFilePath("/Presets/Foo.cdp/ui/index.html"))
        #expect(AgentSettingsBuilder.isBundleFilePath("/Presets/Foo.cdp/ui/style.css"))
        #expect(AgentSettingsBuilder.isBundleFilePath("/Presets/Foo.cdp/ui/widget.js"))
    }

    @Test("isBundleFilePath flags ui/assets/*")
    func matchesUIAssets() {
        #expect(AgentSettingsBuilder.isBundleFilePath("/Presets/Foo.cdp/ui/assets/icon.svg"))
        #expect(AgentSettingsBuilder.isBundleFilePath("/Presets/Foo.cdp/ui/assets/sub/font.woff2"))
    }

    @Test("isBundleFilePath does NOT flag arbitrary files")
    func nonMatches() {
        #expect(!AgentSettingsBuilder.isBundleFilePath("/Users/me/Documents/notes.txt"))
        #expect(!AgentSettingsBuilder.isBundleFilePath("/usr/local/bin/foo"))
        #expect(!AgentSettingsBuilder.isBundleFilePath("/Users/me/Projects/some-repo/README.md"))
        #expect(!AgentSettingsBuilder.isBundleFilePath("/Users/me/file.json"))
        // Empty path
        #expect(!AgentSettingsBuilder.isBundleFilePath(""))
    }

    // MARK: - Hook script behavior (real shell)

    /// Run the hook script with a synthesized JSON payload on stdin and return
    /// (stdout, exit-code).
    private func runHookScript(payload: String) throws -> (stdout: String, exitCode: Int32) {
        // Write the script to a tmp file
        let tmpScript = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bundle-path-hint-\(UUID().uuidString).sh")
        try AgentSettingsBuilder.bundlePathHintScript().write(to: tmpScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpScript.path)
        defer { try? FileManager.default.removeItem(at: tmpScript) }

        let process = Process()
        process.launchPath = "/bin/bash"
        process.arguments = [tmpScript.path]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()  // discard stderr

        try process.run()

        if let data = payload.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (String(data: outData, encoding: .utf8) ?? "", process.terminationStatus)
    }

    @Test("hook script prints hint for manifest.json edits and exits 0")
    func hookHintForManifest() throws {
        let payload = #"{"tool_name":"Edit","tool_input":{"file_path":"/Presets/Foo.cdp/manifest.json"}}"#
        let result = try runHookScript(payload: payload)
        #expect(result.exitCode == 0, "Hook must always exit 0 (advisory)")
        #expect(result.stdout.contains("[skill]"), "Expected [skill] tag, got: \(result.stdout)")
        #expect(result.stdout.contains("write_bundle_file"))
        #expect(result.stdout.contains("/Presets/Foo.cdp/manifest.json"))
    }

    @Test("hook script prints hint for ui/index.html edits")
    func hookHintForUIIndex() throws {
        let payload = #"{"tool_name":"Write","tool_input":{"file_path":"/Presets/Foo.cdp/ui/index.html","content":"<html></html>"}}"#
        let result = try runHookScript(payload: payload)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("[skill]"))
        #expect(result.stdout.contains("/ui/index.html"))
    }

    @Test("hook script prints hint for App-Group Presets path")
    func hookHintForPresetsDirectory() throws {
        let payload = #"{"tool_name":"Edit","tool_input":{"file_path":"/Users/me/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/Presets/MyPreset.cdp/notes.txt"}}"#
        let result = try runHookScript(payload: payload)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("[skill]"))
    }

    @Test("hook script is silent for non-bundle files and exits 0")
    func hookSilentForUnrelatedFiles() throws {
        let payload = #"{"tool_name":"Edit","tool_input":{"file_path":"/Users/me/Documents/notes.txt"}}"#
        let result = try runHookScript(payload: payload)
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Expected no output for non-bundle path, got: \(result.stdout)")
    }

    @Test("hook script handles malformed JSON gracefully (exits 0, no output)")
    func hookHandlesMalformedJSON() throws {
        let payload = "this is not json"
        let result = try runHookScript(payload: payload)
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("hook script handles empty stdin gracefully")
    func hookHandlesEmptyStdin() throws {
        let result = try runHookScript(payload: "")
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("hook script handles MultiEdit payload (extracts edits[0].file_path)")
    func hookHandlesMultiEdit() throws {
        let payload = #"""
        {"tool_name":"MultiEdit","tool_input":{"edits":[{"file_path":"/Presets/Foo.cdp/manifest.json","old_string":"a","new_string":"b"}]}}
        """#
        // Note: the bridge passes file_path on tool_input directly for MultiEdit too in some
        // versions. Test the edits[0] fallback path explicitly.
        let result = try runHookScript(payload: payload)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("[skill]"))
        #expect(result.stdout.contains("manifest.json"))
    }

    @Test("hook script does not block — exits 0 even on match")
    func hookNeverBlocks() throws {
        // PreToolUse hooks block via exit code 2. We must always exit 0.
        let payload = #"{"tool_name":"Edit","tool_input":{"file_path":"/anything/manifest.json"}}"#
        let result = try runHookScript(payload: payload)
        #expect(result.exitCode == 0, "Hook must never use exit 2 (block) — must be advisory only")
    }
}
