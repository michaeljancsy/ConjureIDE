//
//  AgentCatalogTests.swift
//  ConjureDSPLogicTests
//
//  Unit tests for the agent-detection + startup-resolution logic lifted out of
//  PTYManager. Each test builds an AgentCatalog rooted in a throwaway tmp dir,
//  seeds fake binaries and preference files as needed, and asserts the
//  StartupResolution case matches.
//

import Foundation
import Testing

struct AgentCatalogTests {

    /// Helper: build a catalog rooted at a fresh tmp dir, with optional fake binaries.
    /// `installed` maps agent-name → filename to create (made +x).
    /// `useWhich` flips the `which` fallback off by default so tests aren't polluted
    /// by whatever binaries happen to be on the host's PATH.
    static func makeCatalog(
        installed: [String: String] = [:],
        existingStartup: String? = nil,
        existingAgentMode: String? = nil,
        testAgentsOverride: String? = nil,
        useWhich: Bool = false
    ) throws -> (AgentCatalog, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agent-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Stub-binary locations inside the tmp root.
        let binDir = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        // Build per-agent specs. Each stub binary is an executable file whose path
        // sits inside our tmp dir — real binaries on the host are invisible to this
        // catalog because we don't include them in `candidates` and `useWhich` is off.
        var specs: [AgentSpec] = []
        for name in ["claude", "gemini", "codex"] {
            let candidate = binDir.appendingPathComponent(name).path
            if let _ = installed[name] {
                // Make the stub: a small shell script that exits cleanly.
                FileManager.default.createFile(
                    atPath: candidate,
                    contents: "#!/bin/sh\nexit 0\n".data(using: .utf8),
                    attributes: [.posixPermissions: NSNumber(value: 0o755)]
                )
            }
            specs.append(AgentSpec(name: name, candidates: [candidate]))
        }

        let startupPath = root.appendingPathComponent("startup-command").path
        let agentModePath = root.appendingPathComponent("agent-mode").path

        if let existing = existingStartup {
            try existing.write(toFile: startupPath, atomically: true, encoding: .utf8)
        }
        if let existing = existingAgentMode {
            try existing.write(toFile: agentModePath, atomically: true, encoding: .utf8)
        }

        let catalog = AgentCatalog(
            agents: specs,
            startupCommandFilePath: startupPath,
            agentModeFilePath: agentModePath,
            manualSentinel: "__manual__",
            testAgentsOverride: testAgentsOverride,
            useWhichFallback: useWhich
        )
        return (catalog, root)
    }

    // MARK: - Detection

    @Test("detectAllAgents returns empty when no binaries exist")
    func detectEmpty() async throws {
        let (catalog, _) = try Self.makeCatalog()
        #expect(catalog.detectAllAgents() == [])
    }

    @Test("detectAllAgents finds only the agents whose stubs were installed")
    func detectSubset() async throws {
        let (catalog, root) = try Self.makeCatalog(installed: ["claude": "", "codex": ""])
        let detected = catalog.detectAllAgents()
        #expect(detected.map { $0.name } == ["claude", "codex"])
        // Paths point into the tmp root.
        #expect(detected.allSatisfy { $0.binaryPath.hasPrefix(root.path) })
    }

    @Test("testAgentsOverride=\"\" forces empty detection even if binaries exist")
    func overrideEmpty() async throws {
        let (catalog, _) = try Self.makeCatalog(
            installed: ["claude": "", "gemini": ""],
            testAgentsOverride: ""
        )
        #expect(catalog.detectAllAgents() == [])
    }

    @Test("testAgentsOverride=\"claude,gemini\" returns exactly those stubs")
    func overrideSpecific() async throws {
        let (catalog, _) = try Self.makeCatalog(testAgentsOverride: "claude,gemini")
        let detected = catalog.detectAllAgents()
        #expect(detected == [
            DetectedAgent(name: "claude", binaryPath: "/usr/bin/true"),
            DetectedAgent(name: "gemini", binaryPath: "/usr/bin/true"),
        ])
    }

    // MARK: - Resolution — first run (empty file)

    @Test("Empty file + 0 agents → noAgents")
    func resolveNoAgents() async throws {
        let (catalog, _) = try Self.makeCatalog()
        #expect(catalog.resolveStartup(detected: []) == .noAgents)
    }

    @Test("Empty file + 1 agent → autoLaunch")
    func resolveAutoLaunch() async throws {
        let (catalog, _) = try Self.makeCatalog(installed: ["claude": ""])
        let detected = catalog.detectAllAgents()
        #expect(catalog.resolveStartup(detected: detected) == .autoLaunch(detected[0]))
    }

    @Test("Empty file + 2+ agents → picker")
    func resolvePicker() async throws {
        let (catalog, _) = try Self.makeCatalog(installed: ["claude": "", "gemini": ""])
        let detected = catalog.detectAllAgents()
        if case .picker(let agents) = catalog.resolveStartup(detected: detected) {
            #expect(agents.count == 2)
            #expect(agents.map { $0.name } == ["claude", "gemini"])
        } else {
            Issue.record("expected .picker")
        }
    }

    // MARK: - Resolution — runCommand path

    @Test("Saved 'claude' + claude installed → runCommand with firstTokenAgent")
    func resolveRunCommandKnown() async throws {
        let (catalog, _) = try Self.makeCatalog(
            installed: ["claude": ""],
            existingStartup: "claude"
        )
        let detected = catalog.detectAllAgents()
        if case .runCommand(let cmd, let agent) = catalog.resolveStartup(detected: detected) {
            #expect(cmd == "claude")
            #expect(agent?.name == "claude")
        } else {
            Issue.record("expected .runCommand")
        }
    }

    @Test("Saved 'claude --model sonnet' + claude installed → runCommand preserves full command")
    func resolveRunCommandWithFlags() async throws {
        let (catalog, _) = try Self.makeCatalog(
            installed: ["claude": ""],
            existingStartup: "claude --model sonnet"
        )
        let detected = catalog.detectAllAgents()
        if case .runCommand(let cmd, let agent) = catalog.resolveStartup(detected: detected) {
            #expect(cmd == "claude --model sonnet")
            #expect(agent?.name == "claude")
        } else {
            Issue.record("expected .runCommand")
        }
    }

    @Test("Saved 'claude\\tfoo' (tab separator) → first-token matching still works")
    func resolveRunCommandWithTab() async throws {
        let (catalog, _) = try Self.makeCatalog(
            installed: ["claude": ""],
            existingStartup: "claude\tfoo"
        )
        let detected = catalog.detectAllAgents()
        if case .runCommand(_, let agent) = catalog.resolveStartup(detected: detected) {
            #expect(agent?.name == "claude")
        } else {
            Issue.record("expected .runCommand")
        }
    }

    @Test("Saved 'my-custom-cli' (unknown first token) → runCommand with nil firstTokenAgent")
    func resolveRunCommandUnknown() async throws {
        let (catalog, _) = try Self.makeCatalog(
            installed: ["claude": ""],
            existingStartup: "my-custom-cli --flag"
        )
        let detected = catalog.detectAllAgents()
        if case .runCommand(let cmd, let agent) = catalog.resolveStartup(detected: detected) {
            #expect(cmd == "my-custom-cli --flag")
            #expect(agent == nil)
        } else {
            Issue.record("expected .runCommand with nil agent")
        }
    }

    // MARK: - Resolution — agentMissing

    @Test("Saved 'claude' + claude NOT installed → agentMissing with other available agents")
    func resolveAgentMissingWithOthers() async throws {
        let (catalog, _) = try Self.makeCatalog(
            installed: ["gemini": "", "codex": ""],
            existingStartup: "claude"
        )
        let detected = catalog.detectAllAgents()
        if case .agentMissing(let name, let others) = catalog.resolveStartup(detected: detected) {
            #expect(name == "claude")
            #expect(others.map { $0.name } == ["gemini", "codex"])
        } else {
            Issue.record("expected .agentMissing")
        }
    }

    @Test("Saved 'gemini' + nothing installed → agentMissing with empty others")
    func resolveAgentMissingAlone() async throws {
        let (catalog, _) = try Self.makeCatalog(existingStartup: "gemini")
        let detected = catalog.detectAllAgents()
        if case .agentMissing(let name, let others) = catalog.resolveStartup(detected: detected) {
            #expect(name == "gemini")
            #expect(others.isEmpty)
        } else {
            Issue.record("expected .agentMissing")
        }
    }

    // MARK: - Resolution — manual
    //
    // `newlyAvailable` is a diff against a baseline captured the first time
    // `resolveStartup` runs after the manual sentinel is set. The first call
    // returns [] (and writes the baseline); only agents installed AFTER that
    // first call show up as newly available. See the doc comment in
    // `AgentCatalog.resolveStartup` for the full rationale.

    @Test("__manual__ sentinel + 0 agents → manual(newlyAvailable: [])")
    func resolveManualEmpty() async throws {
        let (catalog, _) = try Self.makeCatalog(existingStartup: "__manual__")
        #expect(catalog.resolveStartup(detected: []) == .manual(newlyAvailable: []))
    }

    @Test("__manual__ sentinel + 1 agent, first call → manual(newlyAvailable: []) and captures baseline")
    func resolveManualFirstCallCapturesBaseline() async throws {
        let (catalog, _) = try Self.makeCatalog(
            installed: ["gemini": ""],
            existingStartup: "__manual__"
        )
        let detected = catalog.detectAllAgents()
        // First call: no baseline file → write one, return empty.
        #expect(catalog.resolveStartup(detected: detected) == .manual(newlyAvailable: []))
        // Side effect: baseline file now exists and lists the detected agent.
        let baseline = try String(contentsOfFile: catalog.manualBaselineFilePath, encoding: .utf8)
        #expect(baseline.split(separator: "\n").map(String.init) == ["gemini"])
    }

    @Test("__manual__ sentinel + new agent installed after baseline → newlyAvailable lists the diff")
    func resolveManualReportsDiffAgainstBaseline() async throws {
        let (catalog, _) = try Self.makeCatalog(
            installed: ["claude": "", "gemini": ""],
            existingStartup: "__manual__"
        )
        // Pre-write a baseline as if the user picked manual mode when only claude was installed.
        try "claude".write(toFile: catalog.manualBaselineFilePath, atomically: true, encoding: .utf8)
        let detected = catalog.detectAllAgents()
        // Now both claude and gemini are detected, but only gemini is "newly available."
        let result = catalog.resolveStartup(detected: detected)
        guard case .manual(let newlyAvailable) = result else {
            Issue.record("expected .manual"); return
        }
        #expect(newlyAvailable.map { $0.name } == ["gemini"])
    }

    @Test("__manual__ sentinel + same agents as baseline → newlyAvailable empty")
    func resolveManualNoDiffWhenUnchanged() async throws {
        let (catalog, _) = try Self.makeCatalog(
            installed: ["gemini": ""],
            existingStartup: "__manual__"
        )
        try "gemini".write(toFile: catalog.manualBaselineFilePath, atomically: true, encoding: .utf8)
        let detected = catalog.detectAllAgents()
        #expect(catalog.resolveStartup(detected: detected) == .manual(newlyAvailable: []))
    }

    @Test("Switching out of manual clears the baseline so a future manual session captures fresh state")
    func writingNonManualClearsBaseline() async throws {
        let (catalog, _) = try Self.makeCatalog(existingStartup: "__manual__")
        try "claude".write(toFile: catalog.manualBaselineFilePath, atomically: true, encoding: .utf8)
        catalog.writeStartupCommand("claude")
        #expect(!FileManager.default.fileExists(atPath: catalog.manualBaselineFilePath))
    }

    @Test("Re-writing __manual__ keeps the existing baseline (idempotent)")
    func writingManualSentinelKeepsBaseline() async throws {
        let (catalog, _) = try Self.makeCatalog(existingStartup: "__manual__")
        try "claude".write(toFile: catalog.manualBaselineFilePath, atomically: true, encoding: .utf8)
        catalog.writeStartupCommand("__manual__")
        let baseline = try String(contentsOfFile: catalog.manualBaselineFilePath, encoding: .utf8)
        #expect(baseline == "claude")
    }

    // MARK: - Legacy migration

    @Test("Legacy agent-mode='claude' migrates to startup-command='claude'")
    func migrateClaude() async throws {
        let (catalog, _) = try Self.makeCatalog(existingAgentMode: "claude")
        let migrated = catalog.migrateLegacyAgentModeIfNeeded()
        #expect(migrated == true)
        #expect(catalog.readStartupCommand() == "claude")
        #expect(!FileManager.default.fileExists(atPath: catalog.agentModeFilePath))
    }

    @Test("Legacy agent-mode='manual' migrates to __manual__ sentinel")
    func migrateManual() async throws {
        let (catalog, _) = try Self.makeCatalog(existingAgentMode: "manual")
        #expect(catalog.migrateLegacyAgentModeIfNeeded() == true)
        #expect(catalog.readStartupCommand() == "__manual__")
    }

    @Test("Migration is a no-op if startup-command already exists")
    func migrateSkipsWhenAlreadyMigrated() async throws {
        let (catalog, _) = try Self.makeCatalog(
            existingStartup: "claude --model sonnet",
            existingAgentMode: "claude"
        )
        #expect(catalog.migrateLegacyAgentModeIfNeeded() == false)
        // Startup unchanged — the user's customization is preserved.
        #expect(catalog.readStartupCommand() == "claude --model sonnet")
    }

    @Test("Migration no-ops when only agent-mode has an unrecognised value")
    func migrateSkipsGarbage() async throws {
        let (catalog, _) = try Self.makeCatalog(existingAgentMode: "frobnicate")
        #expect(catalog.migrateLegacyAgentModeIfNeeded() == false)
        #expect(catalog.readStartupCommand() == "")
    }

    // MARK: - Persistence round-trips

    @Test("writeStartupCommand(nil) deletes the file")
    func writeNilDeletes() async throws {
        let (catalog, _) = try Self.makeCatalog(existingStartup: "claude")
        catalog.writeStartupCommand(nil)
        #expect(!FileManager.default.fileExists(atPath: catalog.startupCommandFilePath))
    }

    @Test("readStartupCommand trims whitespace and newlines")
    func readTrims() async throws {
        let (catalog, _) = try Self.makeCatalog(existingStartup: "  claude  \n")
        #expect(catalog.readStartupCommand() == "claude")
    }
}
