//
//  PTYManager.swift
//  ConjureDSP
//
//  Manages a pseudo-terminal (pty) running Claude Code CLI.
//  Handles process lifecycle, I/O, and environment configuration.
//

import Foundation
import os.log

private let ptyLog = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PTYManager")

/// Manages a Claude Code CLI process running in a pseudo-terminal.
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

    /// The MCP server port that Claude Code should connect to.
    var mcpServerPort: UInt16?

    /// Path to the context file for --append-system-prompt-file.
    private var contextFilePath: String?

    /// Path to the MCP config file for --mcp-config.
    private var mcpConfigPath: String?

    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start Claude Code in a pty.
    func start() {
        guard case .idle = state else {
            ptyLog.warning("PTY already running or in error state")
            return
        }

        // Find claude CLI
        guard let claudePath = findClaudeCLI() else {
            let errorMsg = "Claude Code CLI not found. Install it from https://claude.ai/download"
            state = .error(errorMsg)
            onStateChange?(.error(errorMsg))
            ptyLog.error("\(errorMsg, privacy: .public)")
            return
        }

        // Write MCP config and context file BEFORE fork — Foundation APIs are not fork-safe
        if let port = mcpServerPort {
            writeMCPConfig(port: port)
        }
        writeContextFile()

        // Prepare C strings before fork (avoid Swift allocations in child)
        let env = buildEnvironment()
        var args = [claudePath, "--dangerously-skip-permissions"]
        if let contextPath = contextFilePath {
            args += ["--append-system-prompt-file", contextPath]
        }
        if let mcpPath = mcpConfigPath {
            args += ["--mcp-config", mcpPath]
        }
        let cPath = strdup(claudePath)!
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
            // Clean up strdup'd memory
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

        // Parent process
        childPID = pid
        state = .running
        onStateChange?(.running)
        ptyLog.info("Started Claude Code (PID \(pid)) on pty fd \(self.masterFD)")

        // Set non-blocking on master fd
        let flags = fcntl(masterFD, F_GETFL)
        fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        // Read output from pty
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            self?.readFromPTY()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.masterFD, fd >= 0 {
                close(fd)
                self?.masterFD = -1
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
        ptyLog.info("Claude Code exited with code \(exitCode)")
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
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.MichaelJancsy.ConjureDSP") {
            try? diag.write(to: url.appendingPathComponent("pty-diag.txt"), atomically: true, encoding: .utf8)
        }

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
    real-time DSP scripts that process live audio. Use the MCP tools to compile scripts, \
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
        "mode": choice("Low", "Mid", "High", default="Mid"),  # dropdown, received as float index
        "ratio": ratio(),           # 1:1-20:1 compression ratio, default 4
    }

    def process(inputs, outputs, frame_count, sample_rate, params):
        # inputs/outputs: list of numpy.float32 arrays, one per channel
        # params: dict of actual values keyed by PARAMS names (e.g. params["cutoff"] = 1000.0)
        for ch in range(len(inputs)):
            for i in range(frame_count):
                outputs[ch][i] = inputs[ch][i]  # passthrough
    ```

    ## Standard Library

    ```python
    from conjuredsp.dsp import db_to_gain, gain_to_db, smooth_coeff, soft_clip, crossfade, lerp, ms_to_samples
    from conjuredsp.buffers import DelayLine      # circular buffer: write(sample), read(delay_samples)
    from conjuredsp.filters import Biquad, BiquadCoeffs  # biquad filter with .lowpass/.highpass/.bandpass/.peak/.notch/.lowshelf/.highshelf/.allpass
    from conjuredsp.osc import LFO                # oscillator: sine/triangle/saw/square, tick() returns [-1,1]
    ```

    Key APIs:
    - `DelayLine(max_samples)` — `.write(sample)`, `.read(delay_samples)` (linear interp), `.read_cubic(delay_samples)`
    - `BiquadCoeffs.lowpass(freq, q, sample_rate)` — also .highpass, .bandpass, .peak(freq,q,gain_db,sr), .notch, .lowshelf, .highshelf, .allpass
    - `Biquad(coeffs)` — `.set_coeffs(coeffs)`, `.process_sample(x)` returns filtered sample
    - `LFO(sample_rate, freq=1.0, waveform="sine")` — `.tick()` returns [-1,1], `.set_freq(hz)`, `.tick_n(n)` returns numpy array
    - `smooth_coeff(time_ms, sample_rate)` → alpha for one-pole smoothing: `state = alpha * state + (1-alpha) * target`

    ## Conventions

    - Persistent state: use module-level globals (e.g., `_filters = None`, initialized on first call)
    - numpy is available; scipy is available for advanced DSP
    - No file I/O or network calls in process() — it runs on the real-time audio thread
    - Up to 16 parameters per script
    - Use `compile_and_run` to load scripts, `get_parameters` to check state, `toggle_bypass` for A/B comparison
    - Rust scripts are also supported (compiled to WASM, takes a few seconds) but Python is preferred for iteration speed
    - IMPORTANT: The user may change scripts via the editor at any time. Never assume a previous script \
    is still loaded — always call `get_script` to check before deciding whether to modify or replace. \
    Do not rely on conversation memory for what script is currently active.
    """

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
