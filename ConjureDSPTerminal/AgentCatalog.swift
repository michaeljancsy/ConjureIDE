//
//  AgentCatalog.swift
//  ConjureDSP
//
//  Agent detection + startup-resolution logic, factored out of PTYManager so
//  the branchy parts can be unit-tested without the PTY/fork machinery.
//  PTYManager instantiates one of these and delegates.
//

import Foundation

/// Static description of a CLI agent the daemon knows how to launch.
struct AgentSpec: Equatable {
    let name: String        // "claude" / "gemini" / "codex"
    let candidates: [String]
}

/// An agent that was actually resolved to an on-disk binary.
struct DetectedAgent: Equatable {
    let name: String
    let binaryPath: String
}

/// How the PTY should start once the shell is alive.
enum StartupResolution: Equatable {
    /// User (or an earlier session) persisted a startup command.
    /// `firstTokenAgent` is set iff the first token matches a known, installed agent.
    case runCommand(String, firstTokenAgent: DetectedAgent?)
    /// Persisted startup command's first token is a known agent that isn't currently installed.
    case agentMissing(name: String, others: [DetectedAgent])
    /// First-run, exactly one agent detected — auto-launch it.
    case autoLaunch(DetectedAgent)
    /// First-run, multiple agents detected — prompt the user in-terminal.
    case picker([DetectedAgent])
    /// First-run, no agents detected — show the install banner.
    case noAgents
    /// User explicitly chose manual mode. `newlyAvailable` lists agents that were
    /// NOT installed when the user chose manual but are installed now.
    case manual(newlyAvailable: [DetectedAgent])
}

/// Detection + resolution for supported AI-CLI agents.
///
/// Pure-function-friendly: all state is on disk (via injected paths) or in the
/// environment (via an injected env var lookup). Tests construct a catalog with
/// a `tmpDir`-rooted filesystem and stub candidate paths.
struct AgentCatalog {

    /// Manual-mode sentinel stored in the startup-command file.
    let manualSentinel: String

    /// Known agents + their candidate binary paths, in detection order.
    let agents: [AgentSpec]

    /// Absolute path to the startup-command preference file.
    let startupCommandFilePath: String

    /// Absolute path to the legacy agent-mode file (migrated lazily).
    let agentModeFilePath: String

    /// Optional test hook: env-var value. When present and non-nil, `detectAllAgents()`
    /// returns exactly the listed names (comma-separated), each stubbed to `/usr/bin/true`.
    /// Empty string means "force zero agents detected". Used by the UI-test suite because
    /// the XCUITest runner's sandbox blocks renaming user binaries.
    let testAgentsOverride: String?

    /// Whether to fall back to `which <name>` when no candidate path resolves.
    let useWhichFallback: Bool

    init(
        agents: [AgentSpec],
        startupCommandFilePath: String,
        agentModeFilePath: String,
        manualSentinel: String = "__manual__",
        testAgentsOverride: String? = nil,
        useWhichFallback: Bool = true
    ) {
        self.agents = agents
        self.startupCommandFilePath = startupCommandFilePath
        self.agentModeFilePath = agentModeFilePath
        self.manualSentinel = manualSentinel
        self.testAgentsOverride = testAgentsOverride
        self.useWhichFallback = useWhichFallback
    }

    // MARK: - Detection

    /// Probe every agent in `agents` and return those whose binary resolves.
    /// Honors `testAgentsOverride` when set.
    func detectAllAgents() -> [DetectedAgent] {
        if let override = testAgentsOverride {
            let names = override.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return names.map { DetectedAgent(name: $0, binaryPath: "/usr/bin/true") }
        }
        return agents.compactMap { spec in
            guard let path = findAgentCLI(name: spec.name, candidates: spec.candidates) else {
                return nil
            }
            return DetectedAgent(name: spec.name, binaryPath: path)
        }
    }

    /// Look for a single agent's binary. Checks `candidates` in order, then optionally `which`.
    func findAgentCLI(name: String, candidates: [String]) -> String? {
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            if FileManager.default.fileExists(atPath: path) {
                let resolved = (path as NSString).resolvingSymlinksInPath
                if FileManager.default.isExecutableFile(atPath: resolved) {
                    return resolved
                }
                // Sandbox can block isExecutableFile — trust existence.
                return path
            }
        }

        guard useWhichFallback else { return nil }
        return runWhich(name)
    }

    // MARK: - Resolution

    /// Pick a StartupResolution given the current detected agents and persisted file state.
    func resolveStartup(detected: [DetectedAgent]) -> StartupResolution {
        let savedRaw = (try? String(contentsOfFile: startupCommandFilePath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if savedRaw == manualSentinel {
            // Manual mode: `newlyAvailable` is "agents installed since the user
            // chose manual mode," not "every agent currently installed." We
            // persist a baseline (snapshot of detected names taken on the
            // first resolveStartup call after the sentinel is set) and report
            // the diff against it on every subsequent call.
            //
            // The shell function `conjure-use-manual` writes only the
            // sentinel — there's no Swift-side hook to capture a baseline
            // at selection time — so we capture lazily on first read. The
            // first call after manual selection sees no baseline file,
            // writes one with the current detected set, and returns
            // newlyAvailable: [] (correct: nothing is "newly available"
            // relative to "what we just installed"). Adding an agent later
            // makes it appear in newlyAvailable. Removing an agent shrinks
            // detected but doesn't shrink the baseline (so re-installing
            // the same agent later wouldn't trip the banner — niche).
            //
            // The baseline file is co-located with the startup-command file
            // and is cleared in `writeStartupCommand` whenever a non-manual
            // value is written, so a user who flips to claude and back to
            // manual gets a fresh baseline the second time around.
            let baseline = readManualBaseline()
            if baseline == nil {
                writeManualBaseline(names: detected.map { $0.name })
                return .manual(newlyAvailable: [])
            }
            let baseSet = Set(baseline!)
            let diff = detected.filter { !baseSet.contains($0.name) }
            return .manual(newlyAvailable: diff)
        }

        if !savedRaw.isEmpty {
            let firstToken = firstShellToken(savedRaw)
            if agents.contains(where: { $0.name == firstToken }) {
                if let agent = detected.first(where: { $0.name == firstToken }) {
                    return .runCommand(savedRaw, firstTokenAgent: agent)
                } else {
                    return .agentMissing(name: firstToken, others: detected)
                }
            } else {
                return .runCommand(savedRaw, firstTokenAgent: nil)
            }
        }

        switch detected.count {
        case 0: return .noAgents
        case 1: return .autoLaunch(detected[0])
        default: return .picker(detected)
        }
    }

    // MARK: - Persistence

    /// Write the startup command (pass nil to delete the file → triggers detection next time).
    ///
    /// Side effect: writing anything other than `manualSentinel` clears the manual-mode
    /// baseline file. This guarantees a fresh baseline gets captured the next time the
    /// user flips back to manual mode — without the clear, a user who picked manual,
    /// switched to claude, and later went back to manual would diff against the FIRST
    /// manual session's baseline (so agents installed during the claude period would
    /// silently NOT trigger the "newly available" banner).
    func writeStartupCommand(_ value: String?) {
        let fm = FileManager.default
        let dir = (startupCommandFilePath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let value {
            try? value.write(toFile: startupCommandFilePath, atomically: true, encoding: .utf8)
            if value != manualSentinel {
                try? fm.removeItem(atPath: manualBaselineFilePath)
            }
        } else {
            try? fm.removeItem(atPath: startupCommandFilePath)
            try? fm.removeItem(atPath: manualBaselineFilePath)
        }
    }

    /// Path to the manual-mode baseline file. Co-located with the startup-command file
    /// (named `<startup-command>.manual-baseline`). Stores one detected-agent name per
    /// line. Existence of this file means "manual mode has been resolved at least once
    /// already; treat the listed names as the baseline for newlyAvailable diffs."
    var manualBaselineFilePath: String {
        return startupCommandFilePath + ".manual-baseline"
    }

    /// Returns the persisted manual-mode baseline (one name per line) or nil if no
    /// baseline has been captured yet.
    private func readManualBaseline() -> [String]? {
        guard let raw = try? String(contentsOfFile: manualBaselineFilePath, encoding: .utf8) else {
            return nil
        }
        return raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Persist the baseline. Called lazily from `resolveStartup` on the first call
    /// after the manual sentinel is set.
    private func writeManualBaseline(names: [String]) {
        let dir = (manualBaselineFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let body = names.joined(separator: "\n")
        try? body.write(toFile: manualBaselineFilePath, atomically: true, encoding: .utf8)
    }

    /// Returns the raw startup-command content, trimmed. Empty string if the file is missing.
    func readStartupCommand() -> String {
        return (try? String(contentsOfFile: startupCommandFilePath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// If the legacy `agent-mode` file is present and `startup-command` is not, translate
    /// (`claude` → `claude`, `manual` → `__manual__`) and delete the legacy file.
    /// Returns true iff a migration occurred.
    @discardableResult
    func migrateLegacyAgentModeIfNeeded() -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: startupCommandFilePath) else { return false }
        guard let raw = try? String(contentsOfFile: agentModeFilePath, encoding: .utf8) else { return false }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "claude":
            writeStartupCommand("claude")
        case "manual":
            writeStartupCommand(manualSentinel)
        default:
            return false
        }
        try? fm.removeItem(atPath: agentModeFilePath)
        return true
    }

    // MARK: - Diagnostics

    /// Write a human-readable snapshot of what was checked and found. Safe to ignore errors.
    func writeDiagnostics(to url: URL, realHome: String) {
        var diag = "[PTY] detectAllAgents: home=\(realHome)\n"
        if let override = testAgentsOverride {
            diag += "  test-override: \(override)\n"
        }
        for spec in agents {
            for path in spec.candidates {
                let exists = FileManager.default.fileExists(atPath: path)
                let executable = FileManager.default.isExecutableFile(atPath: path)
                diag += "  [\(spec.name)] \(path): exists=\(exists), executable=\(executable)\n"
            }
        }
        try? diag.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    /// Extract the first whitespace-separated token of a shell command. Does not
    /// interpret quoting — our use case is "is the first word a known agent name?".
    private func firstShellToken(_ s: String) -> String {
        return s.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? s
    }

    /// Fallback: `/usr/bin/which <name>`. Returns nil on non-zero exit or empty output.
    private func runWhich(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: - Defaults for the production daemon

    /// Default candidate-path map used when PTYManager spins up a production catalog.
    static func defaultAgents(homeDirectory: String) -> [AgentSpec] {
        return [
            AgentSpec(name: "claude", candidates: [
                "/usr/local/bin/claude",
                "\(homeDirectory)/.claude/local/claude",
                "\(homeDirectory)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
            ]),
            AgentSpec(name: "gemini", candidates: [
                "/usr/local/bin/gemini",
                "\(homeDirectory)/.local/bin/gemini",
                "/opt/homebrew/bin/gemini",
            ]),
            AgentSpec(name: "codex", candidates: [
                "/usr/local/bin/codex",
                "\(homeDirectory)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
            ]),
        ]
    }
}
