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
    static let startupCommandFilePath: String =
        realHomeDirectory + "/Library/Application Support/ConjureDSP/startup-command"

    /// Path to the legacy agent-mode preference file (migrated lazily).
    static let agentModeFilePath: String =
        realHomeDirectory + "/Library/Application Support/ConjureDSP/agent-mode"

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

        // Determine user's shell
        let env = buildEnvironment()
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        // Login shell: argv[0] prefixed with "-" tells the shell to source login profiles
        let shellName = "-" + (shellPath as NSString).lastPathComponent
        let args = [shellName]

        let cPath = strdup(shellPath)!
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) }
        cEnv.append(nil)

        // Create pty
        var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

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
        let detected = catalog.detectAllAgents()
        let resolution = catalog.resolveStartup(detected: detected)
        let mcpURL = mcpServerPort.map { "http://localhost:\($0)/mcp" } ?? "http://localhost:<port>/mcp"
        // Publish the URL for shell-side conjure-mcp-connect-* to read. The file
        // is 0600 and rewritten every session.
        try? mcpURL.write(toFile: Self.mcpUrlFilePath, atomically: true, encoding: .utf8)
        let modeSetup = buildModeSetupCommands(detected: detected)

        // Write modeSetup to a per-session tmp file and `source` it from the shell —
        // much cleaner than pasting ~2KB of shell functions into the PTY (avoids TTY
        // echo spam AND any zsh parser edge cases around complex function definitions).
        let setupPath = NSTemporaryDirectory()
            + "conjuredsp-setup-\(ProcessInfo.processInfo.processIdentifier)-\(UInt64.random(in: 0..<UInt64.max)).sh"
        do {
            try modeSetup.write(toFile: setupPath, atomically: true, encoding: .utf8)
        } catch {
            ptyLog.warning("Failed to write modeSetup file: \(error.localizedDescription, privacy: .public)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            // Disable the TTY's input echo NOW (not earlier — zsh's login-shell
            // initialization, /etc/zprofile etc., reapplies the default termios
            // after forkpty, so a disable in start() gets overridden by the time
            // we write here). Each launch/fallback line in applyResolution appends
            // `stty echo` so the user's post-agent prompt has echo back on.
            self.disablePTYEcho()
            // Source the setup file silently (defines aliases + conjure-use-* + picker fn)
            // then delete it. No `clear` here — it races with onDisplayText and would wipe
            // the install/manual banner before the user sees it.
            self.write("source \(self.shellQuote(setupPath)) 2>/dev/null; rm -f \(self.shellQuote(setupPath)) 2>/dev/null\n")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.applyResolution(resolution, mcpURL: mcpURL)
            }
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

    /// Turn off the ECHO flag on the master fd so writes from the daemon don't get
    /// echoed back as if the user were typing them. Called once per session, right
    /// before we begin writing setup/launch bytes. The shell-side `stty echo` that
    /// each branch of `applyResolution` appends to its launch line is what eventually
    /// restores echo for the post-agent prompt.
    private func disablePTYEcho() {
        guard masterFD >= 0 else { return }
        var tios = termios()
        guard tcgetattr(masterFD, &tios) == 0 else {
            ptyLog.warning("tcgetattr failed: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        tios.c_lflag &= ~tcflag_t(ECHO | ECHOE | ECHOK | ECHONL)
        if tcsetattr(masterFD, TCSANOW, &tios) != 0 {
            ptyLog.warning("tcsetattr failed: \(String(cString: strerror(errno)), privacy: .public)")
        }
    }

    /// Execute the side-effects for a `StartupResolution`: emit banners and
    /// control messages, and write the launch command into the PTY. MCP
    /// wire-up for gemini/codex runs shell-side (via `conjure-mcp-connect-*`
    /// functions defined in modeSetup) — the daemon cannot reliably spawn
    /// node-shebang CLIs itself because launchd's PATH excludes the user's
    /// Node install. See `buildModeSetupCommands()` for the shell helpers.
    private func applyResolution(_ resolution: StartupResolution, mcpURL: String) {
        // Shell fragment that restores TTY echo for the post-agent prompt.
        // Appended to every command line we write while echo is disabled.
        let restoreEcho = "stty echo 2>/dev/null"

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
                self?.writeLaunch("\(fullCmd); \(restoreEcho)\n")
            }

        case .autoLaunch(let agent):
            catalog.writeStartupCommand(agent.name)
            let fullCmd = wrapInWorkspace("conjure-mcp-connect-\(agent.name); \(agent.name)", isExec: false)
            DispatchQueue.main.async { [weak self] in
                self?.onControlMessage?(["type": "agentLaunching", "agent": agent.name, "cmd": agent.name])
                self?.writeLaunch("\(fullCmd); \(restoreEcho)\n")
            }

        case .picker(let agents):
            DispatchQueue.main.async { [weak self] in
                self?.onControlMessage?(["type": "agentPicker", "agents": agents.map { $0.name }])
                // Picker needs echo on so the user can see what they type at the `> ` prompt.
                self?.writeLaunch("\(restoreEcho); __conjuredsp_pick_agent\n")
            }

        case .noAgents:
            DispatchQueue.main.async { [weak self] in
                self?.onControlMessage?(["type": "noAgentsInstalled"])
                self?.writeLaunch("\(restoreEcho)\n")
                self?.onDisplayText?(self!.buildNoAgentsBanner(mcpURL: mcpURL))
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
                self.writeLaunch("\(restoreEcho)\n")
                self.onDisplayText?(self.buildManualBanner(mcpURL: mcpURL, newlyAvailable: newlyAvailable))
            }

        case .agentMissing(let name, let others):
            DispatchQueue.main.async { [weak self] in
                self?.onControlMessage?(["type": "agentMissing", "agent": name])
                self?.writeLaunch("\(restoreEcho)\n")
                self?.onDisplayText?(self!.buildAgentMissingBanner(
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
        guard masterFD >= 0 else { return }
        var winSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        ioctl(masterFD, TIOCSWINSZ, &winSize)
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

    // MARK: - Environment

    private func buildEnvironment() -> [String] {
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

    def process(inputs, outputs, frame_count, sample_rate, params):
        # inputs/outputs: list of numpy.float32 arrays, one per channel
        # params: dict keyed by PARAMS names (e.g. params["cutoff"] = 1000.0)
        for ch in range(len(inputs)):
            for i in range(frame_count):
                outputs[ch][i] = inputs[ch][i]  # passthrough
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
        channels: i32, frame_count: i32, sample_rate: f32,
    ) {
        let ctx = ctx(input, output, channels, frame_count, sample_rate);
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

    ## Latency Reporting

    Scripts that introduce algorithmic latency (lookahead, FFT windowing, oversampling) must \
    declare it so the DAW can compensate.

    - **Python:** `LATENCY = 256` (module-level constant, in samples)
    - **Rust:** `latency!(256);` (macro)

    Do NOT declare latency for creative delay effects (delay, chorus, reverb) — those are \
    intentional and must not be compensated.

    ## MCP tool reference

    Tools are exposed under the `conjuredsp__` namespace. The core set:

    - `get_script`, `compile_and_run`, `get_error`, `get_parameters`, `set_parameter`, `toggle_bypass`
    - `get_audio_state`, `list_presets`, `save_preset`, `list_packages`, `list_tones`
    - `get_docs` — language-specific conjuredsp API reference by topic
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
          # codex CLI's `mcp add` is stdio-only in current releases. HTTP MCP
          # for codex requires editing ~/.codex/config.toml directly. Surface
          # the action to the user rather than guessing at file edits.
          printf '\\033[33mcodex does not yet support HTTP MCP via CLI. Add the following to ~/.codex/config.toml:\\n[mcp_servers.conjuredsp]\\nurl = "%s"\\033[0m\\n' "$url" >&2
        }
        """

        // Aliases: resolve each agent to its full path so the shell finds it regardless
        // of PATH. Claude gets --mcp-config and --allowedTools baked in.
        var aliasLines: [String] = []
        for agent in detected {
            let aliasValue: String
            if agent.name == "claude", let mcpPath = mcpConfigPath {
                aliasValue = "\(shellQuote(agent.binaryPath)) --allowedTools 'mcp__conjuredsp__*' --mcp-config \(shellQuote(mcpPath))"
            } else {
                aliasValue = shellQuote(agent.binaryPath)
            }
            aliasLines.append("alias \(agent.name)=\(shellQuote(aliasValue))")
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
            caseLines.append("    \(idx)) conjure-use-\(agent.name); conjure-mcp-connect-\(agent.name); cd \(workspace) && exec \(agent.name) ;;")
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
