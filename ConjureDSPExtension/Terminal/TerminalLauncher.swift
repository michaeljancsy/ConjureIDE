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
    @MainActor func openURL(_ url: URL) -> Bool
}

/// Default implementation using NSWorkspace.
struct WorkspaceTerminalLauncher: TerminalLaunchable {

    @MainActor func isAppRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    @MainActor func openURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// Launches ConjureDSPTerminal in the background if it isn't already running.
/// Uses a custom URL scheme (`conjuredsp-terminal://launch`) because
/// `NSWorkspace.openApplication` doesn't work from the AUv3 ViewBridge XPC process.
@MainActor
final class TerminalLauncher {

    static let terminalBundleID = "com.MichaelJancsy.ConjureDSPTerminal"
    static let launchURL = URL(string: "conjuredsp-terminal://launch")!

    private let workspace: any TerminalLaunchable

    nonisolated init(workspace: any TerminalLaunchable = WorkspaceTerminalLauncher()) {
        self.workspace = workspace
    }

    /// Launch the companion app if needed. Safe to call multiple times.
    func launchIfNeeded() {
        if workspace.isAppRunning(bundleID: Self.terminalBundleID) {
            log.debug("ConjureDSPTerminal already running — skipping launch")
            return
        }

        if workspace.openURL(Self.launchURL) {
            log.info("Launched ConjureDSPTerminal via URL scheme")
        } else {
            log.warning("Failed to launch ConjureDSPTerminal — companion app may not be installed")
        }
    }
}
