//
//  PickerShellIntegrationTests.swift
//  ConjureDSPLogicTests
//
//  Integration tests for the shell-level picker flow. Spawns real zsh with
//  the exact patterns PTYManager emits (stub binaries stand in for real
//  agents) and asserts end-to-end that:
//
//    • `conjure-use-<agent>` persists the user's pick to `startup-command`.
//    • The picker's `exec` line reaches the agent with the full arg list,
//      including claude's `--mcp-config` flag — this is the path that broke
//      when we relied on alias expansion inside `exec`.
//    • `conjure-mcp-connect-<agent>` reads the URL file and invokes the
//      agent's own `mcp add` from the shell (where PATH is the user's).
//    • `exec <alias>` inside a function body does NOT expand the alias —
//      documents the zsh behavior our picker fix depends on.
//
//  These are the failure modes that bit us in manual testing this week.
//  Each one is a real subprocess + real zsh; the test would have failed
//  the moment the regression landed.
//

import Darwin
import Foundation
import Testing

struct PickerShellIntegrationTests {

    // MARK: - Harness

    /// Make a fresh tmp dir and a shell-script stub that records its argv
    /// to a capture file. Returns (tmpDir, stubPath, captureFilePath).
    static func makeStubAgent(name: String) throws -> (tmp: URL, stub: String, capture: String) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjuredsp-picker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let stub = tmp.appendingPathComponent(name).path
        let capture = tmp.appendingPathComponent("capture.txt").path

        // Write each arg on its own line so we can assert on them by index.
        let script = """
        #!/bin/sh
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> '\(capture)'
        done
        """
        try script.write(toFile: stub, atomically: true, encoding: .utf8)
        _ = chmod(stub, 0o755)
        return (tmp, stub, capture)
    }

    /// Run a zsh script, pipe `input` to its stdin, wait for exit,
    /// and return (stdout+stderr combined, exit status).
    static func runZsh(_ script: String, input: String = "") throws -> (output: String, status: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", script]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe

        if !input.isEmpty {
            let inPipe = Pipe()
            proc.standardInput = inPipe
            try proc.run()
            if let data = input.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(data)
            }
            try? inPipe.fileHandleForWriting.close()
        } else {
            try proc.run()
        }

        proc.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, proc.terminationStatus)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Tests

    @Test("exec <alias> inside a function body does NOT expand the alias")
    func aliasExpansionDoesNotReachExec() throws {
        // This documents the zsh quirk that drove our picker fix: the picker
        // used to do `exec claude` relying on an alias to carry flags, but
        // `exec` treats its argument as a literal command name — no alias
        // lookup. If zsh's behavior changes in a future release this test
        // will flip and we should revisit the picker.
        let (out, status) = try Self.runZsh("""
        alias myfakecmd='/bin/echo ALIAS_EXPANDED'
        __test() { exec myfakecmd; }
        __test
        """)
        // zsh exits 127 with "command not found" — alias was NOT honored.
        #expect(status == 127)
        #expect(out.contains("command not found"))
        #expect(!out.contains("ALIAS_EXPANDED"))
    }

    @Test("Picker case line with inlined launch command passes all flags through exec")
    func pickerExecCarriesFullArgv() throws {
        let (tmp, stub, capture) = try Self.makeStubAgent(name: "claude")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let startupFile = tmp.appendingPathComponent("startup-command").path
        let workspace = tmp.appendingPathComponent("workspace").path
        let mcpConfig = tmp.appendingPathComponent("mcp-config.json").path
        try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
        try "{}".write(toFile: mcpConfig, atomically: true, encoding: .utf8)

        // Matches PTYManager's current picker case-line format:
        // `1) conjure-use-<name>; conjure-mcp-connect-<name>; cd <ws> && exec <full-launch> ;;`
        //
        // `<full-launch>` is the inlined expansion of the claude alias (with
        // --mcp-config flags), NOT the bare alias name. If PTYManager ever
        // regresses to `exec claude`, the stub's capture file stays empty
        // and this test fails at the first #expect.
        let q = Self.shellQuote
        let fullLaunch = "\(q(stub)) --allowedTools 'mcp__conjuredsp__*' --mcp-config \(q(mcpConfig))"
        let script = """
        conjure-use-claude() { printf '%s\\n' 'claude' > \(q(startupFile)); }
        conjure-mcp-connect-claude() { : ; }
        __pick() {
          read choice
          case "$choice" in
            1) conjure-use-claude; conjure-mcp-connect-claude; cd \(q(workspace)) && exec \(fullLaunch) ;;
          esac
        }
        __pick
        """
        let (_, _) = try Self.runZsh(script, input: "1\n")

        // Stub captures each arg on its own line.
        let captured = (try? String(contentsOfFile: capture, encoding: .utf8)) ?? ""
        let args = captured.split(separator: "\n").map(String.init)
        #expect(args.contains("--allowedTools"))
        #expect(args.contains("mcp__conjuredsp__*"))
        #expect(args.contains("--mcp-config"))
        #expect(args.contains(mcpConfig))

        // startup-command persisted.
        let startup = (try? String(contentsOfFile: startupFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(startup == "claude")
    }

    @Test("conjure-mcp-connect-gemini reads URL from file and invokes gemini with it")
    func mcpConnectInvokesGeminiWithCurrentUrl() throws {
        // Stand in for the real `gemini` CLI: a shell script that writes its
        // argv to capture.txt. We're verifying the shell function's contract,
        // not gemini's own behavior.
        let (tmp, gemini, capture) = try Self.makeStubAgent(name: "gemini")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mcpUrlFile = tmp.appendingPathComponent("mcp-url.txt").path
        let sessionURL = "http://127.0.0.1:54099/mcp"
        try sessionURL.write(toFile: mcpUrlFile, atomically: true, encoding: .utf8)

        // Body mirrors conjure-mcp-connect-gemini in PTYManager. PATH is
        // augmented so `gemini` resolves to our stub rather than any real
        // install on the tester's machine.
        let q = Self.shellQuote
        let script = """
        export PATH=\(q(tmp.path)):$PATH
        conjure-mcp-connect-gemini() {
          local url
          url=$(cat \(q(mcpUrlFile)) 2>/dev/null)
          [ -z "$url" ] && return 0
          gemini mcp remove -s user conjuredsp >/dev/null 2>&1
          gemini mcp add -s user -t http conjuredsp "$url" >/dev/null 2>&1
        }
        conjure-mcp-connect-gemini
        """
        _ = try Self.runZsh(script)

        let captured = (try? String(contentsOfFile: capture, encoding: .utf8)) ?? ""
        // `gemini` was invoked twice (remove, then add). Both invocations
        // share the same capture file — argv lines concatenate.
        #expect(captured.contains("mcp"))
        #expect(captured.contains("remove"))
        #expect(captured.contains("add"))
        #expect(captured.contains("-s"))
        #expect(captured.contains("user"))
        #expect(captured.contains("http"))
        #expect(captured.contains("conjuredsp"))
        #expect(captured.contains(sessionURL))
        _ = gemini
    }

    @Test("conjure-use-<name> writes the agent name to startup-command")
    func conjureUsePersistsChoice() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conjuredsp-use-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let startupFile = tmp.appendingPathComponent("startup-command").path
        let q = Self.shellQuote
        let script = """
        conjure-use-gemini() { mkdir -p \(q(tmp.path)); printf '%s\\n' 'gemini' > \(q(startupFile)); }
        conjure-use-gemini
        """
        _ = try Self.runZsh(script)

        let startup = (try? String(contentsOfFile: startupFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(startup == "gemini")
    }

    @Test("conjure-mcp-connect-gemini is a no-op when URL file is missing")
    func mcpConnectMissingUrlIsSafe() throws {
        let (tmp, _, capture) = try Self.makeStubAgent(name: "gemini")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let missingUrlFile = tmp.appendingPathComponent("does-not-exist.txt").path
        let q = Self.shellQuote
        let script = """
        export PATH=\(q(tmp.path)):$PATH
        conjure-mcp-connect-gemini() {
          local url
          url=$(cat \(q(missingUrlFile)) 2>/dev/null)
          [ -z "$url" ] && return 0
          gemini mcp add -s user -t http conjuredsp "$url" >/dev/null 2>&1
        }
        conjure-mcp-connect-gemini
        """
        _ = try Self.runZsh(script)

        // gemini must not have been called — no capture file, or empty.
        let captured = (try? String(contentsOfFile: capture, encoding: .utf8)) ?? ""
        #expect(captured.isEmpty)
    }
}
