//
//  TerminalSettingsView.swift
//  ConjureDSPExtension
//
//  Settings row for the embedded terminal: lets the user view and edit the
//  startup command that the daemon runs when the terminal panel opens.
//  Also surfaces MCP wire-up status per supported agent.
//
//  The `startup-command` file in `~/Library/Application Support/ConjureDSP/`
//  is the single source of truth. Fresh install → empty; populates after the
//  daemon resolves detection on the first terminal open.
//

import Combine
import Darwin
import SwiftUI

/// File-backed @Observable store for the startup-command preference. Mirrored into
/// `<realHome>/Library/Application Support/ConjureDSP/startup-command`. Reads the
/// file on init; writes the file on `set`. Shared with the daemon via the filesystem —
/// no App Group container indirection because the file lives in the *real* user
/// Application Support, not a sandboxed Group Container path.
@MainActor
final class TerminalStartupCommandStore: ObservableObject {
    @Published var value: String = ""

    /// `__manual__` sentinel in the file → UI shows an empty field with a "manual"
    /// placeholder. Exposed so the view can distinguish this state from "fresh install".
    @Published var isManualSentinel: Bool = false

    /// True when the backing file is missing entirely (fresh install).
    @Published var isUnset: Bool = true

    private let filePath: String
    private let manualSentinel = "__manual__"

    init() {
        // The file must live in the App Group container — that's the only
        // path both the sandboxed extension and the unsandboxed daemon can
        // access. `~/Library/Application Support/ConjureDSP/` is outside the
        // extension's sandbox and silently returns nil on read here.
        self.filePath = AppGroupContainer.url
            .appendingPathComponent("startup-command")
            .path
        reload()
    }

    /// Re-read the file. Call from a file-system observer or on view refresh.
    func reload() {
        guard let raw = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            self.value = ""
            self.isManualSentinel = false
            self.isUnset = true
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isUnset = false
        if trimmed == manualSentinel {
            self.value = ""
            self.isManualSentinel = true
        } else {
            self.value = trimmed
            self.isManualSentinel = false
        }
    }

    /// Write the user's edit. Empty → `__manual__` sentinel (distinguishes cleared from unset).
    func set(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let toWrite = trimmed.isEmpty ? manualSentinel : trimmed
        let dir = (filePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? toWrite.write(toFile: filePath, atomically: true, encoding: .utf8)
        reload()
    }

    /// Delete the file — forces re-detection on the next terminal open.
    func reset() {
        try? FileManager.default.removeItem(atPath: filePath)
        reload()
    }
}

struct TerminalSettingsView: View {
    @StateObject private var store = TerminalStartupCommandStore()
    @State private var draft: String = ""
    @State private var mcpStatus: [String: MCPStatus] = [:]

    enum MCPStatus: Equatable {
        case notInstalled
        case connected
        case notConnected
        case unknown
    }

    private let supportedAgents = ["claude", "gemini", "codex"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terminal")
                .font(.headline)

            Text("Startup Command")
                .font(.subheadline)

            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.set(draft) }
                .onChange(of: store.value) { _, newValue in
                    draft = newValue
                }

            HStack(spacing: 8) {
                Button("Save") { store.set(draft) }
                    .disabled(draft == effectiveCurrent)
                Button("Reset") {
                    store.reset()
                    draft = ""
                }
                .disabled(store.isUnset)
                Text("Takes effect on next terminal open.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Button("Relaunch terminal") { requestRelaunch() }
                Text("Ends the current agent session and re-runs detection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Text("ConjureDSP MCP")
                .font(.subheadline)

            ForEach(supportedAgents, id: \.self) { agent in
                HStack {
                    Text(agent)
                        .frame(width: 60, alignment: .leading)
                    Spacer()
                    mcpStatusView(for: agent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Re-read from disk every time the view appears — the @StateObject
            // is created once per view lifetime (often before the daemon's
            // picker writes the file), so the initial value can be stale.
            store.reload()
            draft = store.value
            refreshAllMCPStatus()
        }
    }

    private var placeholder: String {
        if store.isUnset {
            return "Auto-detected on first terminal open"
        } else if store.isManualSentinel {
            return "Manual mode — no command will auto-run"
        } else {
            return ""
        }
    }

    private var effectiveCurrent: String {
        store.isManualSentinel ? "" : store.value
    }

    @ViewBuilder
    private func mcpStatusView(for agent: String) -> some View {
        let status = mcpStatus[agent] ?? .unknown
        switch status {
        case .notInstalled:
            Text("Not installed")
                .font(.caption)
                .foregroundColor(.secondary)
        case .connected:
            HStack(spacing: 4) {
                Text("✓ Connected")
                    .font(.caption)
                    .foregroundColor(.green)
                if agent != "claude" {
                    Button("Disconnect") { disconnectMCP(agent: agent) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        case .notConnected:
            Text("Open the terminal and select \(agent) to connect")
                .font(.caption)
                .foregroundColor(.secondary)
        case .unknown:
            Text("Checking…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func refreshAllMCPStatus() {
        for agent in supportedAgents {
            refreshMCPStatus(for: agent)
        }
    }

    private func refreshMCPStatus(for agent: String) {
        let path = findAgentBinary(name: agent)
        guard let path else {
            mcpStatus[agent] = .notInstalled
            return
        }
        if agent == "claude" {
            // Claude is wired per-invocation via --mcp-config — always "connected"
            // from our perspective when claude is installed.
            mcpStatus[agent] = .connected
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let (ok, output) = runSync([path, "mcp", "list"])
            let connected = ok && output.contains("conjuredsp")
            DispatchQueue.main.async {
                mcpStatus[agent] = connected ? .connected : .notConnected
            }
        }
    }

    /// Touch a signal file the daemon polls for. The daemon's 500ms reconcile
    /// loop detects it, deletes it, and calls `restart()` on active sessions.
    /// See `TerminalAppServer.checkForRelaunchRequest()` in ConjureDSPTerminalApp.swift.
    private func requestRelaunch() {
        let url = AppGroupContainer.url.appendingPathComponent("relaunch-requested")
        try? Data().write(to: url)
    }

    private func disconnectMCP(agent: String) {
        guard let path = findAgentBinary(name: agent) else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = runSync([path, "mcp", "remove", "conjuredsp"])
            DispatchQueue.main.async {
                refreshMCPStatus(for: agent)
            }
        }
    }

    // MARK: - Helpers

    private func findAgentBinary(name: String) -> String? {
        let home: String = {
            if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
                return String(cString: dir)
            }
            return NSHomeDirectory()
        }()
        let candidates: [String]
        switch name {
        case "claude":
            candidates = [
                "/usr/local/bin/claude",
                "\(home)/.claude/local/claude",
                "\(home)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
            ]
        case "gemini":
            candidates = [
                "/usr/local/bin/gemini",
                "\(home)/.local/bin/gemini",
                "/opt/homebrew/bin/gemini",
            ]
        case "codex":
            candidates = [
                "/usr/local/bin/codex",
                "\(home)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
            ]
        default:
            return nil
        }
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}

@MainActor
private func runSync(_ argv: [String]) -> (ok: Bool, output: String) {
    guard let first = argv.first else { return (false, "empty argv") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: first)
    process.arguments = Array(argv.dropFirst())
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch {
        return (false, "launch failed: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return (process.terminationStatus == 0, output)
}
