//
//  PTYManager.swift
//  ConjureDSP
//
//  Manages a pseudo-terminal (pty) running the user's shell.
//  Auto-launches Claude Code CLI on startup; the shell remains
//  usable after Claude exits.
//

import Foundation
import os.log

private let ptyLog = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PTYManager")

/// Manages a pseudo-terminal running the user's shell, with optional auto-launch of Claude Code.
final class PTYManager {

    enum State {
        case idle
        case running
        case exited(Int32)  // exit code
        case error(String)
    }

    enum AgentMode: String {
        case claude   // auto-launch Claude Code if found (default)
        case manual   // open shell only; user manages their own MCP agent
    }

    /// Current state of the pty/process.
    private(set) var state: State = .idle

    /// Called when new output is available from the pty.
    var onOutput: ((Data) -> Void)?

    /// Called when the process state changes.
    var onStateChange: ((State) -> Void)?

    /// Called to display text directly in the terminal (bypasses the PTY).
    var onDisplayText: ((String) -> Void)?

    /// The MCP server port that Claude Code should connect to.
    var mcpServerPort: UInt16?

    /// Path to the context file for --append-system-prompt-file.
    private var contextFilePath: String?

    /// Path to the MCP config file for --mcp-config.
    private var mcpConfigPath: String?

    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var sessionGeneration: UInt64 = 0  // distinguishes fd reuse across sessions
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start the user's shell in a pty, then auto-launch Claude Code.
    func start() {
        switch state {
        case .idle, .exited(_):
            break  // OK to start
        case .running, .error:
            ptyLog.warning("PTY already running or in error state")
            return
        }

        // Clean up stale dispatch sources from a previous session (e.g. restarting
        // from .exited state). Close the old fd eagerly BEFORE cancelling the source,
        // since the cancel handler runs async and would race with the new session's fd.
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        readSource?.cancel()
        readSource = nil
        waitSource?.cancel()
        waitSource = nil
        sessionGeneration &+= 1

        // Write MCP config and context file BEFORE fork — Foundation APIs are not fork-safe
        if let port = mcpServerPort {
            writeMCPConfig(port: port)
        }
        writeContextFile()

        // Find claude CLI for auto-launch (non-fatal if missing — shell still starts)
        let claudePath = findClaudeCLI()

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
            // Child process — only fork-safe calls (no Foundation, no Swift allocations)
            execve(cPath, cArgs, cEnv)
            perror("execve")
            _exit(127)
        }

        // Parent process — clean up strdup'd memory
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

        // Read output from pty — capture generation to detect fd reuse across sessions
        let fd = masterFD
        let gen = sessionGeneration
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            self?.readFromPTY()
        }
        source.setCancelHandler { [weak self] in
            // Close if self is deallocated (deinit path) or this is still the active session.
            // Using generation counter instead of fd comparison to handle fd number reuse.
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

        // Build the full Claude launch command (with MCP flags) used in both claude-mode branches.
        func buildClaudeFullCmd(path: String) -> String {
            var cmd = "\(shellQuote(path)) --allowedTools 'mcp__conjuredsp__*'"
            if let contextPath = contextFilePath {
                cmd += " --append-system-prompt-file \(shellQuote(contextPath))"
            }
            if let mcpPath = mcpConfigPath {
                cmd += " --mcp-config \(shellQuote(mcpPath))"
            }
            return cmd
        }

        let mcpURL = mcpServerPort.map { "http://localhost:\($0)/mcp" } ?? "http://localhost:<port>/mcp"
        let modeSetup = buildModeSetupCommands()

        switch readAgentMode() {
        case .claude:
            if let claudePath {
                // Auto-launch Claude Code; alias lets the user re-launch after exit.
                let fullCmd = buildClaudeFullCmd(path: claudePath)
                let aliasCmd = "alias claude=\(shellQuote(fullCmd))"
                let cmd = modeSetup + "\n" + aliasCmd + "\nclaude\n"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.write(cmd)
                }
            } else {
                ptyLog.warning("Claude Code CLI not found — showing install prompt")
                // Build alias with `command claude` unquoted — shellQuote(path:) is for file
                // paths only; applying it to "command claude" would produce a broken alias.
                var aliasValue = "command claude --allowedTools 'mcp__conjuredsp__*'"
                if let contextPath = contextFilePath {
                    aliasValue += " --append-system-prompt-file \(shellQuote(contextPath))"
                }
                if let mcpPath = mcpConfigPath {
                    aliasValue += " --mcp-config \(shellQuote(mcpPath))"
                }
                let aliasCmd = "alias claude=\(shellQuote(aliasValue))"
                let banner = buildWelcomeBanner(mcpURL: mcpURL)
                let cmd = modeSetup + "\n" + aliasCmd + "\n"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.write(cmd)
                    self?.onDisplayText?(banner)
                }
            }
        case .manual:
            ptyLog.info("External agent mode — skipping Claude auto-launch")
            let banner = buildExternalAgentBanner(mcpURL: mcpURL)
            let cmd = modeSetup + "\n"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.write(cmd)
                self?.onDisplayText?(banner)
            }
        }
    }

    /// Stop the Claude Code process.
    func stop() {
        readSource?.cancel()
        readSource = nil
        waitSource?.cancel()
        waitSource = nil

        if childPID > 0 {
            let pid = childPID
            childPID = 0
            kill(pid, SIGTERM)
            // Reap child in background: wait up to 2s for graceful exit, then SIGKILL
            DispatchQueue.global().async {
                var status: Int32 = 0
                var waited = false
                // Poll for up to 2 seconds
                for _ in 0..<20 {
                    let result = waitpid(pid, &status, WNOHANG)
                    if result == pid {
                        waited = true
                        break
                    }
                    usleep(100_000) // 100ms
                }
                if !waited {
                    kill(pid, SIGKILL)
                    waitpid(pid, &status, 0) // blocking wait after SIGKILL
                }
            }
        }

        // masterFD is closed by the readSource cancel handler — don't close here
        // to avoid a double-close race with the async cancel handler.

        state = .idle
        onStateChange?(.idle)
    }

    /// Restart the Claude Code process.
    func restart() {
        stop()
        // Small delay to let cleanup finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start()
        }
    }

    // MARK: - I/O

    /// Write data to the pty (user input from terminal UI).
    func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            Darwin.write(masterFD, ptr, buffer.count)
        }
    }

    /// Write a string to the pty.
    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }

    /// Resize the pty window.
    func resize(cols: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var winSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        ioctl(masterFD, TIOCSWINSZ, &winSize)
    }

    /// Send SIGWINCH to the child process to force a screen redraw.
    /// Used when a new xterm.js client connects to an already-running PTY.
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
        // WIFEXITED/WEXITSTATUS are C macros not available in Swift — inline the logic
        let normalExit = (status & 0x7f) == 0
        let exitCode: Int32 = normalExit ? ((status >> 8) & 0xff) : -1
        ptyLog.info("Shell exited with code \(exitCode)")
        childPID = 0
        state = .exited(exitCode)
        onStateChange?(.exited(exitCode))
    }

    /// Find the claude CLI in common locations.
    private func findClaudeCLI() -> String? {
        let home = Self.realHomeDirectory
        var diag = "[PTY] findClaudeCLI: realHomeDirectory = \(home)\n"
        let candidates = [
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for path in candidates {
            let exists = FileManager.default.fileExists(atPath: path)
            let executable = FileManager.default.isExecutableFile(atPath: path)
            diag += "  \(path): exists=\(exists), executable=\(executable)\n"
        }
        // Write diagnostics to App Group container (readable from both processes)
        try? diag.write(to: AppGroupContainer.url.appendingPathComponent("pty-diag.txt"), atomically: true, encoding: .utf8)

        for path in candidates {
            // Check the path directly, and also resolve symlinks — the sandbox may
            // block isExecutableFile on symlinks but allow it on the resolved target.
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            if FileManager.default.fileExists(atPath: path) {
                let resolved = (path as NSString).resolvingSymlinksInPath
                if FileManager.default.isExecutableFile(atPath: resolved) {
                    return resolved
                }
                // File exists but can't verify executable — trust it (sandbox limitation)
                return path
            }
        }

        // Try `which claude` as fallback
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }

        return nil
    }

    /// The real user home directory (not the sandbox container).
    /// `NSHomeDirectory()` returns the container path in sandboxed extensions;
    /// `getpwuid` returns the actual `/Users/<name>` path.
    static let realHomeDirectory: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    /// Path to the agent mode preference file.
    static let agentModeFilePath: String =
        realHomeDirectory + "/Library/Application Support/ConjureDSP/agent-mode"

    /// Read the persisted agent mode. Defaults to `.claude` if file is absent or unrecognised.
    private func readAgentMode() -> AgentMode {
        guard let raw = try? String(contentsOfFile: Self.agentModeFilePath, encoding: .utf8) else {
            return .claude
        }
        return AgentMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .claude
    }

    /// Build environment variables for the child process.
    private func buildEnvironment() -> [String] {
        var env: [String: String] = [:]

        // Inherit useful environment variables
        let inheritKeys = ["USER", "PATH", "SHELL", "LANG", "TERM", "TMPDIR",
                           "ANTHROPIC_API_KEY", "CLAUDE_CODE_MAX_TURNS"]
        for key in inheritKeys {
            if let value = ProcessInfo.processInfo.environment[key] {
                env[key] = value
            }
        }

        // Use the real home directory, not the sandbox container.
        // Claude Code needs access to ~/.claude/ for config, auth, and settings.
        env["HOME"] = Self.realHomeDirectory

        // Set TERM for proper terminal emulation
        env["TERM"] = "xterm-256color"

        // Ensure a reasonable PATH
        if env["PATH"] == nil {
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        }

        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Write the DSP context file that gives Claude Code project awareness.
    private func writeContextFile() {
        // Use the real home directory (not sandbox container) so the child process
        // can read the file path we pass via --append-system-prompt-file.
        let home = Self.realHomeDirectory
        let dir = URL(fileURLWithPath: home + "/Library/Application Support/ConjureDSP")
        let path = dir.appendingPathComponent("claude-context.md")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.contextContent.write(to: path, atomically: true, encoding: .utf8)
            contextFilePath = path.path
            ptyLog.info("Wrote context file to \(path.path, privacy: .public)")
        } catch {
            ptyLog.warning("Failed to write context file: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Static Context Content

    /// DSP scripting guide injected into Claude Code's system prompt via --append-system-prompt-file.
    private static let contextContent = """
    You are inside ConjureDSP, a macOS AUv3 audio effect plugin. You write and modify \
    real-time DSP scripts that process live audio. Scripts can be Python (runs instantly) \
    or Rust (compiled to WASM, takes a few seconds). Both languages have a `conjuredsp` \
    library with identical DSP building blocks. Use the MCP tools to compile scripts, \
    adjust parameters, and test your work.

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
    The APIs differ in syntax between Python and Rust — once you know which language \
    you're writing, call `get_docs` with the relevant topic to get exact signatures and usage.

    **Parameter builders** — `freq`, `db`, `time_ms`, `mix`, `pct`, `toggle`, `ratio`, `param`. \
    Python also has `choice` for dropdown menus. Customization syntax differs between languages — \
    call `get_docs` with topic "params" for details.

    **DelayLine** — circular buffer with linear and cubic interpolation.

    **BiquadCoeffs + Biquad** — 8 filter types (lowpass, highpass, bandpass, notch, peak, \
    lowshelf, highshelf, allpass). Stateful per-channel filtering.

    **LFO** — low-frequency oscillator. Waveforms: sine, triangle, saw, square.

    **Utilities** — `db_to_gain`, `gain_to_db`, `smooth_coeff`, `ms_to_samples`, \
    `soft_clip`, `lerp`, `crossfade`, and more.

    **Accelerated math** (`accel` module) — hardware-accelerated vectorized operations \
    backed by Apple Accelerate (vDSP/vecLib) via WASM host imports. Functions: `matmul`, \
    `vec_add`, `vec_mul`, `vec_tanh`, `vec_sigmoid`, `vec_add_scalar`. In Rust: \
    `use conjuredsp::accel;` then `accel::matmul(a, b, out, m, k, n)`. In Python: \
    `from conjuredsp.accel import matmul, vec_add, ...`. Used internally by NAM inference \
    but available to any preset for batch math operations. Call `get_docs` with topic \
    "accel" for full API reference.

    **NAM tone models** — Neural Amp Modeling inference for guitar amp/pedal emulation. \
    Call `list_tones` to see available tone models, then use `load_model("tone3000://...")` \
    in a Python script. Call `get_docs` with topic "nam" for usage details.

    **Internal precision** — All conjuredsp library types use f64 internally for precision, \
    even though WASM I/O buffers are f32. In Rust, cast to/from f64 when interfacing with \
    library types. In Python, this is handled automatically.

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
      `<cdp-xy>`, `<cdp-panel auto>`.
    - The webview's CSP blocks fetch/XHR/WebSocket. All assets must live \
      inside the bundle — no CDN imports, no external fonts.
    - File watcher hot-reloads ~300ms after every `write_bundle_file`, so \
      iterate quickly. To scaffold a new bundle with a starter UI, pass \
      `scaffold_ui=true` to `save_preset`.

    Working examples to copy from: `read_bundle_file` on `preset_svf`, \
    `preset_compressor`, `preset_wavefolder`, `preset_mockingbird_at_night_rust`.

    ## Latency Reporting

    Scripts that introduce algorithmic latency (lookahead, FFT windowing, oversampling) \
    should declare it so the DAW can compensate by delaying other tracks.

    **Python:** `LATENCY = 256` (module-level constant, in samples)
    **Rust:** `latency!(256);` (macro that generates a WASM export)

    Do NOT declare latency for creative delay effects (delay lines, chorus, reverb) — \
    those are intentional and should not be compensated.

    Example: a lookahead limiter delays input by 256 samples to detect peaks before they \
    arrive, enabling transparent gain reduction. The DAW delays other tracks by 256 samples \
    to keep everything in sync.

    ## Conventions

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
    - **Language selection**: Write in whatever language the user asks for. If the user doesn't specify, \
    call `get_script` to check the currently loaded script and write in the same language.
    - IMPORTANT: The user may change scripts via the editor at any time. Never assume a previous script \
    is still loaded — always call `get_script` to check before deciding whether to modify or replace. \
    Do not rely on conversation memory for what script is currently active.
    """

    /// Shell function definitions for switching agent mode, written on every terminal start.
    /// The functions write to the preference file and print a confirmation message.
    private func buildModeSetupCommands() -> String {
        let prefPath = shellQuote(Self.agentModeFilePath)
        let prefDir  = shellQuote((Self.agentModeFilePath as NSString).deletingLastPathComponent)
        let useClaude   = "conjure-use-claude()   { mkdir -p \(prefDir); echo claude > \(prefPath); printf '\\033[32mClaude Code will auto-launch next session. Restart the terminal to apply.\\033[0m\\n'; }"
        let useExternal = "conjure-use-external() { mkdir -p \(prefDir); echo manual > \(prefPath); printf '\\033[32mExternal agent mode set. Claude will not auto-launch next session.\\033[0m\\n'; }"
        return useClaude + "\n" + useExternal
    }

    /// ANSI banner shown when Claude Code is not found (sent directly to xterm.js via WebSocket).
    private func buildWelcomeBanner(mcpURL: String) -> String {
        let esc = "\u{1b}"
        return [
            "",
            "\(esc)[1;36m  ConjureDSP - AI Terminal\(esc)[0m",
            "  -----------------------------------------",
            "",
            "  Claude Code CLI was not found.",
            "  This terminal connects an AI coding agent to ConjureDSP via MCP,",
            "  enabling it to compile scripts, adjust parameters, and test audio.",
            "",
            "  \(esc)[1mTo install Claude Code (requires Node.js):\(esc)[0m",
            "",
            "    npm install -g @anthropic-ai/claude-code",
            "",
            "  After installing, type claude to start.",
            "",
            "  \(esc)[2mUsing a different MCP-compatible agent? Connect it to:\(esc)[0m",
            "  \(esc)[2m  \(mcpURL)\(esc)[0m",
            "  \(esc)[2mThen type conjure-use-external to disable this message.\(esc)[0m",
            "",
        ].joined(separator: "\r\n") + "\r\n"
    }

    /// ANSI banner for external agent mode (sent directly to xterm.js via WebSocket).
    private func buildExternalAgentBanner(mcpURL: String) -> String {
        let esc = "\u{1b}"
        return [
            "",
            "\(esc)[1;36m  ConjureDSP - AI Terminal  \(esc)[2m[external agent mode]\(esc)[0m",
            "  -----------------------------------------",
            "",
            "  \(esc)[32mMCP server: \(mcpURL)\(esc)[0m",
            "",
            "  \(esc)[2mType conjure-use-claude to switch back to Claude Code auto-launch.\(esc)[0m",
            "",
        ].joined(separator: "\r\n") + "\r\n"
    }

    /// Shell-escape a path by wrapping in single quotes (handles spaces, parens, etc.).
    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Write a temporary MCP config file for Claude Code to discover the local MCP server.
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
