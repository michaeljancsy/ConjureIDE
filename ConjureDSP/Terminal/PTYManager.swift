//
//  PTYManager.swift
//  ConjureDSP
//
//  Manages a pseudo-terminal (pty) running Claude Code CLI.
//  Handles process lifecycle, I/O, and environment configuration.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PTYManager")

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
            log.warning("PTY already running or in error state")
            return
        }

        // Find claude CLI
        guard let claudePath = findClaudeCLI() else {
            let errorMsg = "Claude Code CLI not found. Install it from https://claude.ai/download"
            state = .error(errorMsg)
            onStateChange?(.error(errorMsg))
            log.error("\(errorMsg, privacy: .public)")
            return
        }

        // Create pty
        var slaveFD: Int32 = -1
        var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

        let pid = forkpty(&masterFD, nil, nil, &winSize)

        if pid < 0 {
            let errorMsg = "forkpty failed: \(String(cString: strerror(errno)))"
            state = .error(errorMsg)
            onStateChange?(.error(errorMsg))
            log.error("\(errorMsg, privacy: .public)")
            return
        }

        if pid == 0 {
            // Child process — exec claude
            var env = buildEnvironment()
            var args = [claudePath, "--dangerously-skip-permissions"]

            // Configure MCP server if port is available
            if let port = mcpServerPort {
                // Claude Code will be configured via environment or config file
                // The MCP server URL is passed via a temporary config
                writeMCPConfig(port: port)
            }

            // Convert to C strings
            let cArgs = args.map { strdup($0) } + [nil]
            let cEnv = env.map { strdup($0) } + [nil]

            execve(claudePath, cArgs, cEnv)

            // If execve returns, it failed
            perror("execve")
            _exit(127)
        }

        // Parent process
        childPID = pid
        state = .running
        onStateChange?(.running)
        log.info("Started Claude Code (PID \(pid)) on pty fd \(self.masterFD)")

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
            kill(childPID, SIGTERM)
            // Give it a moment, then force kill
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [pid = childPID] in
                kill(pid, SIGKILL)
            }
            childPID = 0
        }

        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }

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
        log.info("Claude Code exited with code \(exitCode)")
        childPID = 0
        state = .exited(exitCode)
        onStateChange?(.exited(exitCode))
    }

    /// Find the claude CLI in common locations.
    private func findClaudeCLI() -> String? {
        let candidates = [
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
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

    /// Build environment variables for the child process.
    private func buildEnvironment() -> [String] {
        var env: [String: String] = [:]

        // Inherit useful environment variables
        let inheritKeys = ["HOME", "USER", "PATH", "SHELL", "LANG", "TERM", "TMPDIR",
                           "ANTHROPIC_API_KEY", "CLAUDE_CODE_MAX_TURNS"]
        for key in inheritKeys {
            if let value = ProcessInfo.processInfo.environment[key] {
                env[key] = value
            }
        }

        // Set TERM for proper terminal emulation
        env["TERM"] = "xterm-256color"

        // Ensure a reasonable PATH
        if env["PATH"] == nil {
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        }

        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Write a temporary MCP config file for Claude Code to discover the local MCP server.
    private func writeMCPConfig(port: UInt16) {
        let configDir = NSHomeDirectory() + "/.claude"
        let configPath = configDir + "/conjuredsp-mcp.json"

        let config: [String: Any] = [
            "mcpServers": [
                "conjuredsp": [
                    "type": "sse",
                    "url": "http://localhost:\(port)/mcp",
                ]
            ]
        ]

        do {
            try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
            try data.write(to: URL(fileURLWithPath: configPath))
            log.info("Wrote MCP config to \(configPath, privacy: .public)")
        } catch {
            log.warning("Failed to write MCP config: \(error.localizedDescription, privacy: .public)")
        }
    }
}
