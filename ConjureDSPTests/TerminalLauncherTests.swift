//
//  TerminalLauncherTests.swift
//  ConjureDSPTests
//

import Testing
import AppKit

// MARK: - Mock

@MainActor
final class MockTerminalLaunchable: TerminalLaunchable, @unchecked Sendable {
    var isRunning = false
    var openURLResult = true
    var openCalled = false
    var openedURL: URL?

    private(set) var isAppRunningBundleIDs: [String] = []

    func isAppRunning(bundleID: String) -> Bool {
        isAppRunningBundleIDs.append(bundleID)
        return isRunning
    }

    func openURL(_ url: URL) -> Bool {
        openCalled = true
        openedURL = url
        return openURLResult
    }
}

// MARK: - Unit Tests

@Suite(.serialized)
struct TerminalLauncherTests {

    @Test @MainActor func launchesWhenNotRunning() {
        let mock = MockTerminalLaunchable()
        mock.isRunning = false
        let launcher = TerminalLauncher(workspace: mock)

        launcher.launchIfNeeded()

        #expect(mock.openCalled)
        #expect(mock.openedURL == TerminalLauncher.launchURL)
    }

    @Test @MainActor func skipsWhenAlreadyRunning() {
        let mock = MockTerminalLaunchable()
        mock.isRunning = true
        let launcher = TerminalLauncher(workspace: mock)

        launcher.launchIfNeeded()

        #expect(!mock.openCalled)
    }

    @Test @MainActor func handlesOpenURLFailure() {
        let mock = MockTerminalLaunchable()
        mock.isRunning = false
        mock.openURLResult = false
        let launcher = TerminalLauncher(workspace: mock)

        // Should not crash — failure is logged
        launcher.launchIfNeeded()

        #expect(mock.openCalled)
    }

    @Test @MainActor func passesCorrectBundleID() {
        let mock = MockTerminalLaunchable()
        mock.isRunning = false
        let launcher = TerminalLauncher(workspace: mock)

        launcher.launchIfNeeded()

        #expect(mock.isAppRunningBundleIDs == [TerminalLauncher.terminalBundleID])
    }

    @Test @MainActor func usesCorrectURLScheme() {
        #expect(TerminalLauncher.launchURL.scheme == "conjuredsp-terminal")
    }

    // MARK: - Integration test (real NSWorkspace)

    @Test @MainActor func realWorkspaceReportsTerminalNotRunning() {
        // Exercises the real NSWorkspace wrapper — isAppRunning should return false
        // in the test environment since ConjureDSPTerminal isn't running.
        // NOTE: We don't call launchIfNeeded() here because NSWorkspace.open(url)
        // with an unregistered URL scheme shows a system dialog, blocking the test runner.
        let workspace = WorkspaceTerminalLauncher()
        let running = workspace.isAppRunning(bundleID: TerminalLauncher.terminalBundleID)
        #expect(!running)
    }
}
