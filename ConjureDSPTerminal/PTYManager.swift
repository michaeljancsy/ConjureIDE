//
//  PTYManager.swift
//  ConjureDSP
//
//  Manages a pseudo-terminal (pty) running the user's shell.
//  Detects supported AI CLI agents (claude, gemini, codex) and either
//  auto-launches the selected one, asks the user to pick, or drops to a
//  plain shell. The shell remains usable after the agent exits.
//

import Foundation
import os.log

private let ptyLog = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PTYManager")

/// Manages a pseudo-terminal running the user's shell, with optional auto-launch of an AI agent.
final class PTYManager {

    enum State {
        case idle
        case running
        case exited(Int32)  // exit code
        case error(String)
    }

    /// Current state of the pty/process.
    private(set) var state: State = .idle

    /// Called when new output is available from the pty.
    var onOutput: ((Data) -> Void)?

    /// Called when the process state changes.
    var onStateChange: ((State) -> Void)?

    /// Called to display text directly in the terminal (bypasses the PTY).
    var onDisplayText: ((String) -> Void)?

    /// Called to send a JSON control message to the terminal JS bridge.
    var onControlMessage: (([String: Any]) -> Void)?

    /// Query: is at least one verified WebSocket client currently connected?
    /// Used by applyResolution to decide whether to write the launch command
    /// immediately or queue it until a client connects.
    var hasVerifiedClient: (() -> Bool)?

    /// The MCP server port that agents should connect to.
    var mcpServerPort: UInt16?

    /// Path to the MCP config file for claude's --mcp-config flag.
    private var mcpConfigPath: String?

    /// Queue for the launch command. Enqueuing routes to an immediate PTY
    /// write if a verified xterm is connected, or parks the command until
    /// `flushPendingLaunch()` is called. See LaunchQueue.swift for rationale.
    private lazy var launchQueue: LaunchQueue = LaunchQueue(
        isConnected: { [weak self] in self?.hasVerifiedClient?() ?? false },
        deliver: { [weak self] cmd in self?.write(cmd) }
    )

    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var sessionGeneration: UInt64 = 0  // distinguishes fd reuse across sessions
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?
    private var lastWinsize: winsize?

    deinit {
        stop()
    }

    // MARK: - Paths

    /// The real user home directory (not the sandbox container).
    static let realHomeDirectory: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    /// Path to the startup-command preference file (current format).
    /// Lives in the App Group container so the sandboxed extension's Settings
    /// pane can read/write it too. Both processes have the App Group
    /// entitlement; neither can access paths outside of it.
    static let startupCommandFilePath: String =
        AppGroupContainer.url.appendingPathComponent("startup-command").path

    /// Path to the legacy agent-mode preference file (migrated lazily).
    static let agentModeFilePath: String =
        AppGroupContainer.url.appendingPathComponent("agent-mode").path

    /// Directory the daemon cd's into before launching an agent. Contains CLAUDE.md,
    /// GEMINI.md, and AGENTS.md with the DSP guidance each CLI auto-reads.
    static let agentWorkspacePath: String =
        realHomeDirectory + "/Library/Application Support/ConjureDSP/agent-workspace"

    /// Path the daemon writes the current session's MCP URL to on every `start()`.
    /// Shell-side `conjure-mcp-connect-*` functions read this to wire up agent
    /// MCP configs with the right port — the daemon cannot reliably run the
    /// agent CLIs itself because those CLIs are node shebang scripts and the
    /// daemon's launchd-inherited PATH does not include the user's Node install.
    static let mcpUrlFilePath: String =
        realHomeDirectory + "/Library/Application Support/ConjureDSP/mcp-url.txt"

    /// Detection + resolution delegate (testable in isolation via `AgentCatalog`).
    private lazy var catalog: AgentCatalog = AgentCatalog(
        agents: AgentCatalog.defaultAgents(homeDirectory: Self.realHomeDirectory),
        startupCommandFilePath: Self.startupCommandFilePath,
        agentModeFilePath: Self.agentModeFilePath,
        testAgentsOverride: ProcessInfo.processInfo.environment["CONJUREDSP_TEST_AGENTS"]
    )

    // MARK: - Lifecycle

    /// Start the user's shell in a pty and kick off the agent-resolution flow.
    func start() {
        switch state {
        case .idle, .exited(_):
            break  // OK to start
        case .running, .error:
            ptyLog.warning("PTY already running or in error state")
            return
        }

        // Clean up stale dispatch sources from a previous session.
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        readSource?.cancel()
        readSource = nil
        waitSource?.cancel()
        waitSource = nil
        sessionGeneration &+= 1

        // Write MCP config and workspace files BEFORE fork — Foundation APIs are not fork-safe.
        if let port = mcpServerPort {
            writeMCPConfig(port: port)
        }
        writeAgentWorkspace()
        catalog.migrateLegacyAgentModeIfNeeded()

        // Detect agents and build setup BEFORE fork (pure FS ops — safe here, forbidden after fork).
        // Injected via ZDOTDIR so setup sources silently as part of zsh's own startup;
        // no PTY writes or echo manipulation needed.
        let detected = catalog.detectAllAgents()
        let resolution = catalog.resolveStartup(detected: detected)
        let mcpURL = mcpServerPort.map { "http://localhost:\($0)/mcp" } ?? "http://localhost:<port>/mcp"
        try? mcpURL.write(toFile: Self.mcpUrlFilePath, atomically: true, encoding: .utf8)
        let modeSetup = buildModeSetupCommands(detected: detected)
        let setupPath = NSTemporaryDirectory()
            + "conjuredsp-setup-\(ProcessInfo.processInfo.processIdentifier)-\(UInt64.random(in: 0..<UInt64.max)).sh"
        do {
            try modeSetup.write(toFile: setupPath, atomically: true, encoding: .utf8)
        } catch {
            ptyLog.warning("Failed to write modeSetup file: \(error.localizedDescription, privacy: .public)")
        }
        let zdotdir = createZdotdir(setupPath: setupPath)

        // Determine user's shell
        let env = buildEnvironment(zdotdir: zdotdir)
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Login shell: argv[0] prefixed with "-" tells the shell to source login profiles
        let shellName = "-" + (shellPath as NSString).lastPathComponent
        let args = [shellName]

        guard let cPath = strdup(shellPath) else {
            let errorMsg = "strdup failed for shell path (out of memory)"
            state = .error(errorMsg)
            onStateChange?(.error(errorMsg))
            ptyLog.error("\(errorMsg, privacy: .public)")
            return
        }
        guard let cArgs = Self.buildCStringArray(args) else {
            let errorMsg = "strdup failed for argv entry (out of memory)"
            state = .error(errorMsg)
            onStateChange?(.error(errorMsg))
            ptyLog.error("\(errorMsg, privacy: .public)")
            free(cPath)
            return
        }
        guard let cEnv = Self.buildCStringArray(env) else {
            let errorMsg = "strdup failed for envp entry (out of memory)"
            state = .error(errorMsg)
            onStateChange?(.error(errorMsg))
            ptyLog.error("\(errorMsg, privacy: .public)")
            free(cPath)
            cArgs.forEach { if let q = $0 { free(q) } }
            return
        }

        // Create pty. Reuse the last applied winsize across restarts so a
        // relaunched PTY (which keeps the WebSocket open, so no socket.onopen
        // re-sends the size) doesn't start at the hardcoded default and smear
        // Claude's redraws until the user nudges the splitter.
        var winSize = Self.initialWinsize(cached: lastWinsize)

        let pid = forkpty(&masterFD, nil, nil, &winSize)

        if pid < 0 {
            let errorMsg = "forkpty failed: \(String(cString: strerror(errno)))"
            state = .error(errorMsg)
            onStateChange?(.error(errorMsg))
            ptyLog.error("\(errorMsg, privacy: .public)")
            free(cPath)
            cArgs.forEach { if let p = $0 { free(p) } }
            cEnv.forEach { if let p = $0 { free(p) } }
            return
        }

        if pid == 0 {
            // Child process — only fork-safe calls
            execve(cPath, cArgs, cEnv)
            perror("execve")
            _exit(127)
        }

        // Parent
        free(cPath)
        cArgs.forEach { if let p = $0 { free(p) } }
        cEnv.forEach { if let p = $0 { free(p) } }

        childPID = pid
        state = .running
        onStateChange?(.running)
        ptyLog.info("Started shell (PID \(pid)) on pty fd \(self.masterFD)")

        // Set non-blocking on master fd
        let flags = fcntl(masterFD, F_GETFL)
        fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        // Read output from pty
        let fd = masterFD
        let gen = sessionGeneration
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            self?.readFromPTY()
        }
        source.setCancelHandler { [weak self] in
            guard let self else {
                close(fd)
                return
            }
            if self.sessionGeneration == gen {
                close(fd)
                self.masterFD = -1
            }
        }
        source.resume()
        readSource = source

        // Watch for process exit
        let waitSrc = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        waitSrc.setEventHandler { [weak self] in
            self?.handleProcessExit()
        }
        waitSrc.resume()
        waitSource = waitSrc

        catalog.writeDiagnostics(
            to: AppGroupContainer.url.appendingPathComponent("pty-diag.txt"),
            realHome: Self.realHomeDirectory)

        // Setup already injected via ZDOTDIR — apply resolution immediately.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.applyResolution(resolution, mcpURL: mcpURL)
        }
    }

    /// Route a launch command through the LaunchQueue — writes immediately
    /// if a verified xterm is connected, queues otherwise.
    private func writeLaunch(_ cmd: String) {
        let wasPending = launchQueue.hasPending
        launchQueue.enqueue(cmd)
        if launchQueue.hasPending && !wasPending {
            ptyLog.info("Launch command queued — waiting for xterm to verify")
        }
    }

    /// Called by the TerminalApp wiring when a client verifies. Drains any
    /// queued launch command. Idempotent.
    func flushPendingLaunch() {
        guard launchQueue.hasPending else { return }
        ptyLog.info("Flushing queued launch command")
        launchQueue.flush()
    }

    /// Execute the side-effects for a `StartupResolution`: emit banners and
    /// control messages, and write the launch command into the PTY. MCP
    /// wire-up for gemini/codex runs shell-side (via `conjure-mcp-connect-*`
    /// functions defined in modeSetup) — the daemon cannot reliably spawn
    /// node-shebang CLIs itself because launchd's PATH excludes the user's
    /// Node install. See `buildModeSetupCommands()` for the shell helpers.
    private func applyResolution(_ resolution: StartupResolution, mcpURL: String) {
        switch resolution {
        case .runCommand(let cmd, let firstTokenAgent):
            let connect = firstTokenAgent.map { "conjure-mcp-connect-\($0.name); " } ?? ""
            let fullCmd = wrapInWorkspace("\(connect)\(cmd)", isExec: false)
            DispatchQueue.main.async { [weak self] in
                self?.onControlMessage?([
                    "type": "agentLaunching",
                    "agent": firstTokenAgent?.name ?? "custom",
                    "cmd": cmd,
                ])
                self?.writeLaunch("\(fullCmd)\n")
            }

        case .autoLaunch(let agent):
            catalog.writeStartupCommand(agent.name)
            let fullCmd = wrapInWorkspace("conjure-mcp-connect-\(agent.name); \(agent.name)", isExec: false)
            DispatchQueue.main.async { [weak self] in
                self?.onControlMessage?(["type": "agentLaunching", "agent": agent.name, "cmd": agent.name])
                self?.writeLaunch("\(fullCmd)\n")
            }

        case .picker(let agents):
            DispatchQueue.main.async { [weak self] in
                self?.onControlMessage?(["type": "agentPicker", "agents": agents.map { $0.name }])
                self?.writeLaunch("__conjuredsp_pick_agent\n")
            }

        case .noAgents:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onControlMessage?(["type": "noAgentsInstalled"])
                self.onDisplayText?(self.buildNoAgentsBanner(mcpURL: mcpURL))
            }

        case .manual(let newlyAvailable):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !newlyAvailable.isEmpty {
                    self.onControlMessage?([
                        "type": "newAgentHint",
                        "agents": newlyAvailable.map { $0.name },
                    ])
                }
                self.onDisplayText?(self.buildManualBanner(mcpURL: mcpURL, newlyAvailable: newlyAvailable))
            }

        case .agentMissing(let name, let others):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onControlMessage?(["type": "agentMissing", "agent": name])
                self.onDisplayText?(self.buildAgentMissingBanner(
                    name: name, others: others, mcpURL: mcpURL))
            }
        }
    }

    /// Stop the agent process.
    func stop() {
        readSource?.cancel()
        readSource = nil
        waitSource?.cancel()
        waitSource = nil

        if childPID > 0 {
            let pid = childPID
            childPID = 0
            kill(pid, SIGTERM)
            DispatchQueue.global().async {
                var status: Int32 = 0
                var waited = false
                for _ in 0..<20 {
                    let result = waitpid(pid, &status, WNOHANG)
                    if result == pid {
                        waited = true
                        break
                    }
                    usleep(100_000)
                }
                if !waited {
                    kill(pid, SIGKILL)
                    waitpid(pid, &status, 0)
                }
            }
        }

        state = .idle
        onStateChange?(.idle)
    }

    /// Restart the agent process.
    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start()
        }
    }

    // MARK: - I/O

    func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            Darwin.write(masterFD, ptr, buffer.count)
        }
    }

    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        var winSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        // Cache independent of PTY liveness — resizes that arrive during the
        // 500ms gap inside restart(), or while the agent is exited between
        // sessions, still seed the next start()'s initial winsize.
        if cols > 0 && rows > 0 {
            lastWinsize = winSize
        }
        guard masterFD >= 0 else { return }
        ioctl(masterFD, TIOCSWINSZ, &winSize)
    }

    /// Pick the initial winsize for forkpty. Uses the cached size from a prior
    /// `resize()` when it's a sane non-zero value; otherwise falls back to the
    /// standard 24x80 terminal default. Static so tests can exercise the
    /// selection logic without standing up a real PTY.
    static func initialWinsize(cached: winsize?) -> winsize {
        if let last = cached, last.ws_col > 0, last.ws_row > 0 {
            return last
        }
        return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }

    func sendSIGWINCH() {
        guard childPID > 0 else { return }
        kill(childPID, SIGWINCH)
    }

    // MARK: - Private

    private func readFromPTY() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(masterFD, &buffer, buffer.count)
        if bytesRead > 0 {
            let data = Data(bytes: buffer, count: bytesRead)
            DispatchQueue.main.async { [weak self] in
                self?.onOutput?(data)
            }
        }
    }

    private func handleProcessExit() {
        var status: Int32 = 0
        waitpid(childPID, &status, WNOHANG)
        let normalExit = (status & 0x7f) == 0
        let exitCode: Int32 = normalExit ? ((status >> 8) & 0xff) : -1
        ptyLog.info("Shell exited with code \(exitCode)")
        childPID = 0
        state = .exited(exitCode)
        onStateChange?(.exited(exitCode))
    }

    // MARK: - Workspace (CLAUDE.md / GEMINI.md / AGENTS.md)

    /// Write the agent-workspace directory with one context file per agent convention.
    /// Called on every PTY start — idempotent, cheap.
    private func writeAgentWorkspace() {
        let dir = URL(fileURLWithPath: Self.agentWorkspacePath)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for filename in ["CLAUDE.md", "GEMINI.md", "AGENTS.md"] {
                let path = dir.appendingPathComponent(filename)
                try Self.contextContent.write(to: path, atomically: true, encoding: .utf8)
            }
            ptyLog.info("Wrote agent workspace to \(dir.path, privacy: .public)")
        } catch {
            ptyLog.warning("Failed to write agent workspace: \(error.localizedDescription, privacy: .public)")
        }
        writeAgentSettings()
    }

    /// Write `<agent-workspace>/.claude/settings.json` + the `bundle-path-hint.sh`
    /// script it references. The settings.json registers a PreToolUse hook for
    /// Edit / Write / MultiEdit that prints an advisory hint when the file path
    /// looks like a preset-bundle file (manifest.json, process.{py,rs}, ui/*,
    /// or anything under the App Group's `Presets/` directory). Hint nudges
    /// toward `mcp__conjuredsp__write_bundle_file`, which routes through the
    /// AU's MCP server (static validation + hot reload). Advisory only — the
    /// script always exits 0, so the agent can still proceed.
    private func writeAgentSettings() {
        let workspaceDir = URL(fileURLWithPath: Self.agentWorkspacePath)
        let claudeDir = workspaceDir.appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let scriptURL = hooksDir.appendingPathComponent(AgentSettingsBuilder.bundlePathHintScriptName)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        do {
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

            // Hook script — write first, chmod +x, then write settings.json so
            // the settings.json never references a non-executable script.
            let scriptBody = AgentSettingsBuilder.bundlePathHintScript()
            try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            // 0o755 — owner rwx, group/other rx
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )

            let settings = AgentSettingsBuilder.settingsJSON(hookScriptAbsolutePath: scriptURL.path)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL)

            ptyLog.info("Wrote agent settings.json to \(settingsURL.path, privacy: .public)")
        } catch {
            ptyLog.warning("Failed to write agent settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Launch command construction

    /// Wrap a shell command so it runs with PWD = agent workspace (subshell → no CWD leak).
    private func wrapInWorkspace(_ cmd: String, isExec: Bool) -> String {
        let quoted = shellQuote(Self.agentWorkspacePath)
        if isExec {
            return "cd \(quoted) && exec \(cmd)"
        } else {
            return "(cd \(quoted) && \(cmd))"
        }
    }

    // MARK: - ZDOTDIR injection

    /// Create a temp ZDOTDIR containing a `.zshrc` that sources the user's real `~/.zshrc`
    /// then our ConjureDSP setup, then self-destructs. Using ZDOTDIR lets setup run silently
    /// as part of zsh's own startup — no PTY writes, no echo manipulation needed.
    private func createZdotdir(setupPath: String) -> String? {
        let dir = NSTemporaryDirectory()
            + "conjuredsp-zdotdir-\(ProcessInfo.processInfo.processIdentifier)-\(UInt64.random(in: 0..<UInt64.max))"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        } catch {
            ptyLog.warning("Failed to create ZDOTDIR: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let zshrc = """
        [ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"
        source \(shellQuote(setupPath)) 2>/dev/null
        rm -f \(shellQuote(setupPath)) 2>/dev/null
        rm -rf "$ZDOTDIR" 2>/dev/null
        unset ZDOTDIR
        """
        do {
            try zshrc.write(toFile: dir + "/.zshrc", atomically: true, encoding: .utf8)
        } catch {
            ptyLog.warning("Failed to write ZDOTDIR/.zshrc: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(atPath: dir)
            return nil
        }
        return dir
    }

    // MARK: - Environment

    private func buildEnvironment(zdotdir: String? = nil) -> [String] {
        var env: [String: String] = [:]

        let inheritKeys = ["USER", "PATH", "SHELL", "LANG", "TERM", "TMPDIR",
                           "ANTHROPIC_API_KEY", "CLAUDE_CODE_MAX_TURNS"]
        for key in inheritKeys {
            if let value = ProcessInfo.processInfo.environment[key] {
                env[key] = value
            }
        }

        env["HOME"] = Self.realHomeDirectory
        env["TERM"] = "xterm-256color"

        if env["PATH"] == nil {
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        }

        if let zdotdir {
            env["ZDOTDIR"] = zdotdir
        }

        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: - DSP guide content

    /// DSP scripting guide. Written to CLAUDE.md / GEMINI.md / AGENTS.md so each agent
    /// picks it up as project memory from its own convention.
    private static let contextContent = """
    You are a coding assistant running inside ConjureDSP, a macOS AUv3 audio effect plugin. \
    The user writes and modifies real-time DSP scripts that process live audio. Scripts can \
    be Python (runs instantly) or Rust (compiled to WASM, takes a few seconds). Both languages \
    have a `conjuredsp` library with identical DSP building blocks. Use the MCP tools exposed \
    under `conjuredsp__*` to compile scripts, adjust parameters, and test the user's work.

    ## Operating rules

    - Scripts run on the real-time audio thread. The `process()` function must not allocate, \
    perform file I/O, or make network calls.
    - Up to 16 parameters per script.
    - Always call `get_script` before modifying a script — the user may have edited it since the \
    last turn. Never rely on conversation memory for what's currently loaded.
    - Default to Rust unless the user asks for Python or you're revising a script that is already \
    in Python.
    - Call `get_docs` with a topic (params, filters, delays, oscillators, utilities, accel, nam) \
    before writing conjuredsp-library code — Python and Rust have different syntax for the same concepts.
    - Call `list_packages` before assuming a Python package is unavailable.

    ## Honesty and feasibility

    - Don't fabricate user pushback. If you change approach mid-task, say so explicitly \
    ("I'm switching from X to Y because Z"). Never reframe a silent change as if the user \
    asked for it.
    - Verify framework support before pitching architecture. Before proposing a design that \
    depends on a capability (DSP-side param writes, custom panel routing, threading model, an \
    MCP tool you haven't called this session), confirm it exists — read `get_docs`, inspect a \
    working preset with `get_script`, or call the tool with a probe input. Specifically: the \
    `ctx` API in DSP scripts is read-for-params, write-for-output-buffers; there is no \
    DSP-side `ctx.set_param`. Don't pitch "writeable readout params" without checking.
    - `smoke_test_ui` `pass` is binding correctness, not behavioral correctness. It verifies \
    every cdp-* control resolved its `param=` attribute and no JS errors fired during boot. \
    It does NOT play audio through the kernel and watch a meter rise. For UIs whose value \
    is "the visual responds when audio plays" (level meters, spectrum scopes, oscilloscopes, \
    gain-reduction histories), tell the user smoke_test confirms binding only and ask them \
    to play audio and confirm the visual responds.
    - `dsp_probe` is how you verify a DSP edit actually made sound. After a non-trivial \
    `compile_and_run` (new algorithm, parameter wiring change, anything that touches the \
    audio math), call `dsp_probe` once with `signal: "sine"` and check `has_nan` / `has_inf` \
    are false and `out_rms` is in a sensible range for the script (non-zero unless the script \
    is deliberately gating). For filter / delay / dynamics edits, also probe with \
    `signal: "impulse"` and confirm the impulse response peak is non-zero. "The math derives \
    correctly" is not verification — `dsp_probe` is. The probe briefly mutes audio output \
    while it reloads the script to reset DSP state, so don't run it in a tight loop during \
    a user's playback session.

    ## Python DSP Scripts

    ```python
    from conjuredsp import freq, db, time_ms, mix, pct, toggle, choice, ratio

    PARAMS = {
        "cutoff": freq(),           # 20-20000 Hz, log curve, default 1000
        "gain": db(),               # -60 to 12 dB, default 0
        "attack": time_ms(0.5, 50), # 0.5-50 ms, log curve, default ~5
        "mix": mix(),               # 0.0-1.0, default 0.5
        "drive": pct(),             # 0-100%, default 50
        "bypass_eq": toggle(),      # on/off switch (0.0 or 1.0)
        "mode": choice("Low", "Mid", "High", default="Mid"),  # dropdown (Python only)
        "ratio": ratio(),           # 1:1-20:1 compression ratio, default 4
    }

    def process(ctx):
        # The single accepted signature. `ctx` exposes:
        #   ctx.inputs / ctx.outputs — 2D numpy.float32 arrays, shape
        #                              (channels, frame_count); pre-sliced to
        #                              the current block. Whole-array ops
        #                              (np.multiply(ctx.inputs, g, out=ctx.outputs))
        #                              broadcast across both axes. Use
        #                              ctx.inputs[ch] for a 1D row view when
        #                              per-channel state forces a loop.
        #   ctx.frame_count          — valid samples this callback (the 2D
        #                              arrays already slice to this length)
        #   ctx.sample_rate          — Hz
        #   ctx.params               — read-only view: ctx.params["cutoff"]
        #                              or ctx.params.cutoff
        #   ctx.transport            — read-only mapping (bpm, beat, is_playing, ...)
        #   ctx.telemetry            — write per-block scalar readouts
        #   ctx.state                — read-only mapping over the bundle's STATE channel
        #   ctx.sidechain            — 2D numpy.float32 array mirroring inputs;
        #                              zero-filled when no sidechain bus is connected
        # The legacy 7-arg form (inputs, outputs, frame_count, ...) is rejected at
        # script load — kernel logs "process() must take exactly one argument (ctx)".
        np.copyto(ctx.outputs, ctx.inputs)  # passthrough
    ```

    Persistent state: module-level globals (e.g. `_filters = None`, initialized on first call). \
    numpy and scipy are available.

    ## Rust DSP Scripts

    ```rust
    use conjuredsp::*;
    setup!();  // declares buffers, WASM exports, and ctx() helper

    params! {
        CUTOFF = freq(),                                     // index constant + metadata
        FEEDBACK = param(0.0, 0.95).default(0.5),            // generic with chaining
        MIX = mix(),
    }

    // Persistent state via static mut
    static mut FILTERS: [Biquad; 2] = [Biquad::new(); 2];

    #[no_mangle]
    pub extern "C" fn process(
        input: *const f32, output: *mut f32,
        channel_count: i32, frame_count: i32, sample_rate: f32,
    ) {
        // Copy your process() args into ctx() in the same order. Don't rename
        // the third arg to anything that suggests "frames" — Context indexes
        // via channel * frames + frame; mixing the two compiles fine but
        // walks the buffer with the wrong stride and produces silently-wrong
        // output.
        let ctx = ctx(input, output, channel_count, frame_count, sample_rate);
        unsafe {
            let cutoff = ctx.param(CUTOFF);  // actual value (1000.0 Hz), not 0-1
            for c in 0..ctx.channels() {
                for i in 0..ctx.frames() {
                    ctx.set_output(c, i, ctx.input(c, i));  // passthrough
                }
            }
        }
    }
    ```

    `ctx` provides: `.input(ch, frame)`, `.set_output(ch, frame, val)`, `.param(INDEX)`, \
    `.channels()`, `.frames()`, `.sample_rate()`. All `static mut` access requires `unsafe {}`.

    ## Standard Library

    Both languages have a `conjuredsp` library with equivalent DSP building blocks. \
    Call `get_docs` with the relevant topic to see exact signatures and usage for the current language.

    **Parameter builders** — `freq`, `db`, `time_ms`, `mix`, `pct`, `toggle`, `ratio`, `param`. \
    Python also has `choice` for dropdown menus.

    **DelayLine** — circular buffer with linear and cubic interpolation.

    **BiquadCoeffs + Biquad** — 8 filter types (lowpass, highpass, bandpass, notch, peak, \
    lowshelf, highshelf, allpass). Stateful per-channel filtering.

    **LFO** — low-frequency oscillator. Waveforms: sine, triangle, saw, square.

    **Utilities** — `db_to_gain`, `gain_to_db`, `smooth_coeff`, `ms_to_samples`, \
    `soft_clip`, `lerp`, `crossfade`, and more.

    **Accelerated math** (`accel` module) — hardware-accelerated vectorized operations \
    backed by Apple Accelerate (vDSP/vecLib) via WASM host imports. Functions: `matmul`, \
    `vec_add`, `vec_mul`, `vec_tanh`, `vec_sigmoid`, `vec_add_scalar`.

    **NAM tone models** — Neural Amp Modeling inference. Call `list_tones` to discover \
    available models, then `load_model("tone3000://...")` in a Python script.

    **Internal precision** — All conjuredsp library types use f64 internally even though WASM \
    I/O buffers are f32. In Rust, cast to/from f64 at library boundaries. In Python, automatic.

    ## Custom HTML/JS UIs (only when the user asks for one)

    The extension renders a stock slider panel for every preset \
    automatically. Don't touch UI unless the user specifically asks for \
    one — phrases like "custom UI," "visualization," "XY pad," "make it \
    look like X," "skin this," "animated UI." Plain DSP tasks ("write a \
    compressor," "change the attack time," "fix this bug in the script") \
    do NOT need UI work; the stock sliders already cover them.

    When the user IS asking for a custom UI, FIRST call `get_docs` with \
    topic `"ui"` for the full component reference, Canvas patterns, \
    audio-frame API, theming hooks, and gotchas. Don't guess the \
    component API from memory — the most common failure mode of \
    custom UIs is hand-rolling param math against invented metadata \
    field names, producing NaN readouts and dead sliders.

    Quick orientation (full details in the docs):

    - Bundles ship `ui/index.html` + optional `ui/assets/*`; the manifest \
      needs a `ui` block pointing at entryHTML.
    - The webview is pre-injected with `window.ConjureDSP` and \
      `cdp-ui.js`. DO NOT include `<script src="...">` for either.
    - Components available: `<cdp-slider>`, `<cdp-toggle>`, `<cdp-choice>`, \
      `<cdp-xy>`, `<cdp-knob>`, `<cdp-panel auto>`. For circular knobs \
      reach for `<cdp-knob param="…">` instead of hand-rolling SVG — \
      it covers drag (Shift = fine), wheel, keyboard, double-click-to- \
      default, and ARIA. Theme via `--cdp-knob-*` properties; for \
      non-circular geometry slot in your own SVG and react to the \
      published `--cdp-knob-norm` CSS variable.
    - Every cdp-slider / cdp-knob / cdp-choice already renders its own \
      label and formatted value (with units) inside its shadow DOM. \
      DO NOT add a sibling `<span>` / `<div>` / readout that displays \
      the same param value — it shows up twice and the user has to \
      mentally reconcile them. If the default position doesn't fit, \
      style the built-in value via `--cdp-value-width` / \
      `::part(value)` instead of duplicating it.
    - `parameters.set(i, v)` fires `onChange`/`onAnyChange` synchronously \
      (with a dedupe-on-equal guard). Use `ctrl.onChange(cb)` as your \
      single source of truth for visual updates — the same handler \
      runs on the user's drag AND on DAW automation. Never write a \
      pattern that "manually redraws after setValue but ignores \
      onChange" — that worked under an older bridge contract and is \
      now redundant + fragile.
    - The webview's CSP blocks fetch/XHR/WebSocket. All assets must live \
      inside the bundle — no CDN imports, no external fonts.
    - File watcher hot-reloads ~300ms after every `write_bundle_file`, so \
      iterate quickly. To scaffold a new bundle with a starter UI, pass \
      `scaffold_ui=true` to `save_preset`.
    - DO NOT draw the preset's own name ANYWHERE inside `ui/index.html` — \
      not as a header, not as a footer, not as a watermark, not as a \
      subtitle. The plugin/DAW host already shows it in the window title \
      bar. Repeating it wastes vertical viewport space and duplicates the \
      label. Use the UI canvas for the actual controls and visualization \
      only, unless the user asks for it.

    Working examples to copy from: `read_bundle_file` on `preset_svf`, \
    `preset_compressor`, `preset_wavefolder`, `preset_mockingbird_at_night_rust`.

    **Save first, atomically. Don't juggle compile_and_run + save_preset.**

    `save_preset` is atomic: in ONE call it writes the bundle to disk, \
    switches the plugin's current preset to it, AND loads the script \
    into the kernel. You don't need a separate `compile_and_run` after. \
    `compile_and_run` is ONLY for iterative script edits against an \
    already-saved bundle, not for creating new presets.

    `save_preset` always produces a fresh bundle. Nothing is auto-copied \
    from whatever preset the user was previously on. Decide whether the \
    user's request builds on the loaded preset or replaces it:

    - Build-on signals: "add", "change this X", "tweak", "make it more Y", \
      references to visible UI elements or specific params.
    - Start-fresh signals: "make me a", "create a", naming a different \
      effect class than what's loaded.
    - When unsure, start fresh — the recovery is cheap.

    Recommended flow when the user asks for a new preset from scratch \
    (or a completely different preset class from what's loaded):

    1. Call `save_preset(name, source=<DSP script text>, scaffold_ui=true_or_false)`. \
    One call creates the bundle, switches the plugin to it, and loads \
    the script into the kernel. Response has `switched_current_preset: true` \
    and `kernel_reloaded: true`. \
    **Pass `scaffold_ui=true` whenever you plan to ship a custom UI — \
    even if you're about to overwrite `ui/index.html` with your own HTML \
    anyway.** It makes the manifest declare a `ui` block in the same \
    atomic write that creates the bundle. Without it, the plugin renders \
    generic sliders until a later `write_bundle_file` on `manifest.json` \
    adds the block — a visible flash for the user between save and the \
    first UI paint.
    2. If the user wants a custom UI, call `write_bundle_file(\"ui/index.html\", \
    …)` (and any ui/assets/*) to author it. Read the inline `validation` \
    block on each write.
    3. Call `smoke_test_ui` when done to verify the UI works at runtime.

    When the user wants to build on what's currently loaded (e.g. \
    \"tweak the threshold slider color on this compressor\"): \
    `read_bundle_file` the files you want to inherit into your context \
    BEFORE `save_preset`, then after save_preset use `write_bundle_file` \
    to drop the inherited (possibly edited) files into the new bundle. \
    Three explicit steps — no hidden cloning. This keeps the bundle on \
    disk consistent with whatever `source` you save. If the loaded \
    preset ships a custom UI you're inheriting, pass `scaffold_ui=true` \
    to `save_preset` for the same reason as above — avoids the \
    generic-slider flash between save and your first UI overwrite.

    Don't call `compile_and_run` FIRST just to get a script into the \
    kernel before save_preset — pass the source straight to save_preset. \
    Mixing the two tools in sequence creates coordination problems that \
    have burned past sessions: the bundle on disk drifts from what the \
    kernel is running.

    After save_preset, tell the user what you named the new bundle so \
    they can find it in the preset browser.

    **When iterating with `compile_and_run`, finish with `save_preset` to persist the bundle to disk** \
    — `compile_and_run` only updates kernel state, so without a save the script vanishes on the next \
    preset load (or when the DAW project reopens) and the kernel falls back to passthrough.

    **Validation protocol (mandatory before claiming done on a UI task):**

    Two tools, used in sequence. Static lint first (catches authoring \
    mistakes in the source text), then the runtime smoke test (catches \
    failures that only manifest when the UI actually renders).

    - Every `write_bundle_file` to `ui/*` or `manifest.json` returns a \
    `validation` block with a `status` (`pass` / `warn` / `fail`) and an \
    `issues` array. Read it. If `status: "fail"`, fix the failures before \
    continuing — the UI is broken in a way the user will notice.
    - Common failures the static validator catches: unresolved `param="X"` \
    references (including when manifest.params is missing entirely), \
    external `<script src>` / `fetch()` / `WebSocket` calls that the CSP \
    blocks, missing manifest.ui block, Canvas 2D fillStyle set to a CSS \
    system color keyword that won't parse, UIs that declare parameters \
    but expose zero interactive controls, and low text contrast — \
    including cross-rule cases like `body { background: #0a0a0a; }` \
    paired with `.label { color: #555; }` in a separate rule.
    - When you're done with a UI task, call `smoke_test_ui` as a runtime \
    check. It loads the UI in an offscreen WKWebView using the same \
    bridge + cdp-ui.js injection the live plugin uses, then reports: \
    whether `ConjureDSP.ready` fired, every JS error (including ones \
    thrown inside `ready(cb)` that the bridge catches), per-component \
    binding state ("did every cdp-slider actually resolve its param= \
    attribute at runtime?"), and per-declared-parameter coverage ("does \
    every AU parameter have at least one working UI control?"). Don't \
    say "done" until `smoke_test_ui` returns `status: "pass"` (or "warn" \
    with issues you've read and deliberately accepted).
    - The static `validate_bundle` tool re-runs the same lint sweep on \
    demand. Use it when you want to re-check without another write.
    - Do NOT try to validate a UI by asking yourself whether the code \
    looks right — this has produced NaN readouts, dead sliders, dark \
    text on dark backgrounds, and pointer-event ghosts in past sessions. \
    Run the tools.

    ## Latency Reporting

    Scripts that introduce algorithmic latency (lookahead, FFT windowing, oversampling) must \
    declare it so the DAW can compensate.

    - **Python:** `LATENCY = 256` (module-level constant, in samples)
    - **Rust:** `latency!(256);` (macro)

    Do NOT declare latency for creative delay effects (delay, chorus, reverb) — those are \
    intentional and must not be compensated.

    ## MCP tool reference

    Tools are exposed under the `conjuredsp__` namespace. The core set:

    - **Bundle files live outside your cwd.** Anything inside a `.cdp` bundle \
    (`manifest.json`, `process.{py,rs}`, `ui/**`, `state.json`) is in the App Group \
    container, not your working directory. Always use the `read_bundle_file` and \
    `write_bundle_file` MCP tools for these paths — never the harness `Edit` or \
    `Write` tools, which will fail with "File does not exist".
    - No file I/O or network calls in process() — runs on the real-time audio thread
    - Up to 16 parameters per script
    - Use `compile_and_run` to load scripts, `get_parameters` to check state, `toggle_bypass` for A/B
    - Call `list_packages` to see what Python packages are available for import (built-in and user-installed). \
    Do not assume a package is unavailable — always check first.
    - Before writing a script, call `get_docs` for the language-specific API reference. Topics: \
    params, filters, delays, oscillators, utilities, accel, nam. Python and Rust have different \
    syntax for the same concepts — always check.
    - Ignore the custom UI surface entirely unless the user explicitly asks for a custom UI \
    (phrases like "custom UI", "visualization", "XY pad", "make it look like X"). The \
    extension renders stock sliders automatically. If the user IS asking for a custom UI, \
    call `get_docs` with topic `"ui"` before writing any `ui/index.html` — the cdp-ui \
    component API and the window.ConjureDSP bridge aren't guessable from memory.
    - Python loads instantly; Rust compiles to WASM (a few seconds) but runs much faster
    - **Language selection**: Default to Rust unless the user asks for Python or you are revising a \
    script that is already in Python. Always call `get_script` before writing or modifying a script \
    to check the current language — if it's Python, continue in Python unless the user says otherwise.
    - IMPORTANT: The user may change scripts via the editor at any time. Never assume a previous script \
    is still loaded — always call `get_script` to check before deciding whether to modify or replace. \
    Do not rely on conversation memory for what script is currently active.
    """

    // MARK: - Shell helpers (conjure-use-* + picker)

    /// Shell function definitions written at every terminal start. Includes:
    ///   - aliases for every detected agent (full path + MCP flags for claude),
    ///   - `conjure-use-*` switchers that persist the choice,
    ///   - `__conjuredsp_pick_agent` interactive picker.
    private func buildModeSetupCommands(detected: [DetectedAgent]) -> String {
        let prefPath = shellQuote(Self.startupCommandFilePath)
        let prefDir = shellQuote((Self.startupCommandFilePath as NSString).deletingLastPathComponent)
        let workspace = shellQuote(Self.agentWorkspacePath)
        let mcpUrlFile = shellQuote(Self.mcpUrlFilePath)

        // conjure-mcp-connect-<name> shell functions. Called before each agent
        // launch to refresh that agent's ConjureDSP MCP entry with the current
        // session's URL. Runs in the user's shell so PATH is right (these CLIs
        // are typically node shebang scripts, and the daemon cannot reliably
        // find node itself). Failures print a diagnostic but do not block the
        // agent launch — the agent just runs without MCP tools.
        let connectFns = """
        conjure-mcp-connect-claude() { : ; }
        conjure-mcp-connect-gemini() {
          local url
          url=$(cat \(mcpUrlFile) 2>/dev/null)
          if [ -z "$url" ]; then
            printf '\\033[33mConjureDSP MCP URL not found — skipping gemini wire-up.\\033[0m\\n' >&2
            return 0
          fi
          gemini mcp remove -s user conjuredsp >/dev/null 2>&1
          if ! gemini mcp add -s user -t http conjuredsp "$url" >/dev/null 2>&1; then
            printf '\\033[33mgemini mcp add failed — run `gemini mcp add -s user -t http conjuredsp %s` manually.\\033[0m\\n' "$url" >&2
          fi
        }
        conjure-mcp-connect-codex() {
          local url
          url=$(cat \(mcpUrlFile) 2>/dev/null)
          if [ -z "$url" ]; then
            printf '\\033[33mConjureDSP MCP URL not found — skipping codex wire-up.\\033[0m\\n' >&2
            return 0
          fi
          # codex mcp add --url landed via PR #4317 (0.123.0+). Remove-then-add
          # refreshes the URL across sessions (port changes each launch).
          codex mcp remove conjuredsp >/dev/null 2>&1
          if ! codex mcp add conjuredsp --url "$url" >/dev/null 2>&1; then
            printf '\\033[33mcodex mcp add failed — run `codex mcp add conjuredsp --url %s` manually.\\033[0m\\n' "$url" >&2
          fi
        }
        """

        // Aliases: resolve each agent to its full path so the shell finds it regardless
        // of PATH. Claude gets --mcp-config and --allowedTools baked in.
        //
        // Also record per-agent "launch strings" — the fully-expanded command used
        // by the picker's `exec` call sites. `exec <alias-name>` inside a function
        // body does NOT expand the alias (verified in zsh), so we can't rely on
        // alias expansion at exec time. Inline the expanded form in the case line.
        var aliasLines: [String] = []
        var launchStrings: [String: String] = [:]
        for agent in detected {
            let aliasValue: String
            if agent.name == "claude", let mcpPath = mcpConfigPath {
                aliasValue = "\(shellQuote(agent.binaryPath)) --allowedTools 'mcp__conjuredsp__*' --mcp-config \(shellQuote(mcpPath))"
            } else {
                aliasValue = shellQuote(agent.binaryPath)
            }
            aliasLines.append("alias \(agent.name)=\(shellQuote(aliasValue))")
            launchStrings[agent.name] = aliasValue
        }

        // Per-agent switch functions. Writes startup-command and prints a confirmation.
        func switcher(_ name: String) -> String {
            return """
            conjure-use-\(name)() { mkdir -p \(prefDir); printf '%s\\n' '\(name)' > \(prefPath); printf '\\033[32m\(name) will auto-start next session. You can adjust this preference in Settings.\\033[0m\\n'; }
            """
        }

        let useClaude = switcher("claude")
        let useGemini = switcher("gemini")
        let useCodex = switcher("codex")
        let useManual = """
        conjure-use-manual() { mkdir -p \(prefDir); printf '%s\\n' '\(catalog.manualSentinel)' > \(prefPath); printf '\\033[32mManual mode — no auto-start next session. You can adjust this preference in Settings.\\033[0m\\n'; }
        """
        // Back-compat alias for the old external name.
        let useExternal = "conjure-use-external() { conjure-use-manual; }"

        // Interactive picker — numbered prompt that writes the choice and exec's the agent.
        // Only emit options for agents we actually detected.
        //
        // All options are rendered as a single `printf` argument so the function body
        // is plain shell (no bare `1) claude` lines, which would read as case-pattern
        // syntax outside a case block and break the function definition).
        var menuLines: [String] = []
        var caseLines: [String] = []
        var idx = 1
        for agent in detected {
            menuLines.append("  \(idx)) \(agent.name)")
            let launch = launchStrings[agent.name] ?? shellQuote(agent.binaryPath)
            caseLines.append("    \(idx)) conjure-use-\(agent.name); conjure-mcp-connect-\(agent.name); cd \(workspace) && exec \(launch) ;;")
            idx += 1
        }
        menuLines.append("  \(idx)) just a shell")
        caseLines.append("    \(idx)) conjure-use-manual ;;")
        caseLines.append("    *) printf '\\033[33mUnknown choice — staying in shell.\\033[0m\\n'; conjure-use-manual ;;")

        // Build the picker as one printf of the full menu, then read + case. Each line
        // of the function body is a single valid shell command, avoiding zsh's
        // incremental parser tripping into `function quote>` continuations.
        let menuStr = menuLines.joined(separator: "\\n") + "\\n"
        let caseBody = caseLines.joined(separator: "\n")
        let pickerFn = """
        __conjuredsp_pick_agent() {
          printf '\\033[1;36mMultiple agents detected — choose one:\\033[0m\\n\(menuStr)> '
          read choice
          case "$choice" in
        \(caseBody)
          esac
        }
        """

        return (aliasLines + [connectFns, useClaude, useGemini, useCodex, useManual, useExternal, pickerFn])
            .joined(separator: "\n")
    }

    // MARK: - Banners

    private func buildNoAgentsBanner(mcpURL: String) -> String {
        let esc = "\u{1b}"
        return [
            "",
            "\(esc)[1;36m  ConjureDSP — AI Terminal\(esc)[0m",
            "  -----------------------------------------",
            "",
            "  No AI coding agent was found.",
            "  This terminal connects an agent to ConjureDSP via MCP,",
            "  so it can compile scripts, adjust parameters, and test audio.",
            "",
            "  \(esc)[1mSupported agents:\(esc)[0m",
            "    claude    https://claude.com/code",
            "    gemini    https://github.com/google-gemini/gemini-cli",
            "    codex     https://github.com/openai/codex",
            "",
            "  Install one, then reopen this terminal.",
            "",
            "  \(esc)[2mAlready have an MCP-capable agent elsewhere? Connect it to:\(esc)[0m",
            "  \(esc)[2m  \(mcpURL)\(esc)[0m",
            "  \(esc)[2mThen type conjure-use-manual to silence this banner.\(esc)[0m",
            "",
        ].joined(separator: "\r\n") + "\r\n"
    }

    private func buildManualBanner(mcpURL: String, newlyAvailable: [DetectedAgent]) -> String {
        let esc = "\u{1b}"
        var lines = [
            "",
            "\(esc)[1;36m  ConjureDSP — AI Terminal  \(esc)[2m[manual mode]\(esc)[0m",
            "  -----------------------------------------",
            "",
            "  \(esc)[32mMCP server: \(mcpURL)\(esc)[0m",
            "",
        ]
        if !newlyAvailable.isEmpty {
            let names = newlyAvailable.map { $0.name }.joined(separator: ", ")
            lines.append("  \(esc)[33m\(names) \(newlyAvailable.count == 1 ? "is" : "are") now installed.\(esc)[0m")
            for agent in newlyAvailable {
                lines.append("  \(esc)[2mRun `conjure-use-\(agent.name)` to auto-launch it next session.\(esc)[0m")
            }
            lines.append("")
        } else {
            lines.append("  \(esc)[2mType conjure-use-claude / -gemini / -codex to re-enable auto-launch.\(esc)[0m")
            lines.append("")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func buildAgentMissingBanner(name: String, others: [DetectedAgent], mcpURL: String) -> String {
        let esc = "\u{1b}"
        var lines = [
            "",
            "\(esc)[1;36m  ConjureDSP — AI Terminal\(esc)[0m",
            "  -----------------------------------------",
            "",
            "  Your startup command is `\(name)`, but `\(name)` isn't installed.",
            "",
        ]
        if others.isEmpty {
            lines.append("  \(esc)[2mNo other agents detected. Install one or run conjure-use-manual.\(esc)[0m")
        } else {
            lines.append("  \(esc)[1mAvailable agents:\(esc)[0m")
            for agent in others {
                lines.append("    conjure-use-\(agent.name)")
            }
            lines.append("")
            lines.append("  \(esc)[2mOr run conjure-use-manual to drop to a plain shell.\(esc)[0m")
        }
        lines.append("")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - C-string array helpers

    /// Build a null-terminated C-string array from an array of Swift strings, using the
    /// supplied `dupFn` to duplicate each string. Returns `nil` (and frees any already-
    /// allocated entries) if any duplication fails.
    ///
    /// The returned array includes a trailing `nil` sentinel. Callers own the memory
    /// and must free each non-nil element.
    static func buildCStringArray(
        _ strings: [String],
        dupFn: (String) -> UnsafeMutablePointer<CChar>? = { strdup($0) }
    ) -> [UnsafeMutablePointer<CChar>?]? {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for s in strings {
            guard let p = dupFn(s) else {
                result.forEach { if let q = $0 { free(q) } }
                return nil
            }
            result.append(p)
        }
        result.append(nil)
        return result
    }

    // MARK: - Utilities

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - MCP config (claude per-invocation)

    /// Write ~/.claude/conjuredsp-mcp.json for claude's --mcp-config flag.
    private func writeMCPConfig(port: UInt16) {
        let configDir = Self.realHomeDirectory + "/.claude"
        let configPath = configDir + "/conjuredsp-mcp.json"

        let config: [String: Any] = [
            "mcpServers": [
                "conjuredsp": [
                    "type": "http",
                    "url": "http://localhost:\(port)/mcp",
                ]
            ]
        ]

        do {
            try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
            try data.write(to: URL(fileURLWithPath: configPath))
            mcpConfigPath = configPath
            ptyLog.info("Wrote MCP config to \(configPath, privacy: .public)")
        } catch {
            ptyLog.warning("Failed to write MCP config: \(error.localizedDescription, privacy: .public)")
        }
    }
}
