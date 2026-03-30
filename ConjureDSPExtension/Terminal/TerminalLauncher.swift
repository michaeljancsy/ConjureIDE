//
//  TerminalLauncher.swift
//  ConjureDSPExtension
//
//  Automatically launches ConjureDSPTerminal companion app when the AU
//  extension loads in a DAW, so the Claude Code terminal is available
//  without requiring the user to manually start it.
//

import AppKit
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "TerminalLauncher")

/// Abstracts NSWorkspace for testability.
protocol TerminalLaunchable: Sendable {
    @MainActor func isAppRunning(bundleID: String) -> Bool
    @MainActor func urlForApp(bundleID: String) -> URL?
    @MainActor func openApp(at url: URL, activates: Bool) async throws
}

/// Default implementation using NSWorkspace.
struct WorkspaceTerminalLauncher: TerminalLaunchable {

    @MainActor func isAppRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    @MainActor func urlForApp(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    @MainActor func openApp(at url: URL, activates: Bool) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activates
        try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

/// Launches ConjureDSPTerminal in the background if it isn't already running.
@MainActor
final class TerminalLauncher {

    static let terminalBundleID = "com.MichaelJancsy.ConjureDSPTerminal"

    private let workspace: any TerminalLaunchable

    nonisolated init(workspace: any TerminalLaunchable = WorkspaceTerminalLauncher()) {
        self.workspace = workspace
    }

    /// Launch the companion app if needed. Safe to call multiple times.
    func launchIfNeeded() async {
        if workspace.isAppRunning(bundleID: Self.terminalBundleID) {
            log.debug("ConjureDSPTerminal already running — skipping launch")
            return
        }

        guard let appURL = workspace.urlForApp(bundleID: Self.terminalBundleID) else {
            log.warning("ConjureDSPTerminal not found — companion app is not installed")
            return
        }

        do {
            try await workspace.openApp(at: appURL, activates: false)
            log.info("Launched ConjureDSPTerminal in background")
        } catch {
            log.warning("Failed to launch ConjureDSPTerminal: \(error.localizedDescription, privacy: .public)")
        }
    }
}
