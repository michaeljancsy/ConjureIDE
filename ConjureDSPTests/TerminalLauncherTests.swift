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
    var appURL: URL? = URL(fileURLWithPath: "/Applications/ConjureDSPTerminal.app")
    var openCalled = false
    var openActivatesValue: Bool?
    var openError: Error?

    private(set) var isAppRunningBundleIDs: [String] = []
    private(set) var urlForAppBundleIDs: [String] = []

    func isAppRunning(bundleID: String) -> Bool {
        isAppRunningBundleIDs.append(bundleID)
        return isRunning
    }

    func urlForApp(bundleID: String) -> URL? {
        urlForAppBundleIDs.append(bundleID)
        return appURL
    }

    func openApp(at url: URL, activates: Bool) async throws {
        if let error = openError { throw error }
        openCalled = true
        openActivatesValue = activates
    }
}

// MARK: - Unit Tests

@Suite(.serialized)
struct TerminalLauncherTests {

    @Test @MainActor func launchesWhenNotRunning() async {
        let mock = MockTerminalLaunchable()
        mock.isRunning = false
        let launcher = TerminalLauncher(workspace: mock)

        await launcher.launchIfNeeded()

        #expect(mock.openCalled)
        #expect(mock.openActivatesValue == false)
    }

    @Test @MainActor func skipsWhenAlreadyRunning() async {
        let mock = MockTerminalLaunchable()
        mock.isRunning = true
        let launcher = TerminalLauncher(workspace: mock)

        await launcher.launchIfNeeded()

        #expect(!mock.openCalled)
    }

    @Test @MainActor func handlesAppNotInstalled() async {
        let mock = MockTerminalLaunchable()
        mock.isRunning = false
        mock.appURL = nil
        let launcher = TerminalLauncher(workspace: mock)

        await launcher.launchIfNeeded()

        #expect(!mock.openCalled)
    }

    @Test @MainActor func passesCorrectBundleID() async {
        let mock = MockTerminalLaunchable()
        mock.isRunning = false
        let launcher = TerminalLauncher(workspace: mock)

        await launcher.launchIfNeeded()

        #expect(mock.isAppRunningBundleIDs == [TerminalLauncher.terminalBundleID])
        #expect(mock.urlForAppBundleIDs == [TerminalLauncher.terminalBundleID])
    }

    @Test @MainActor func handlesLaunchError() async {
        let mock = MockTerminalLaunchable()
        mock.isRunning = false
        mock.openError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "sandbox blocked"])
        let launcher = TerminalLauncher(workspace: mock)

        // Should not throw — errors are logged, not propagated
        await launcher.launchIfNeeded()
    }

    // MARK: - Integration test (real NSWorkspace)

    @Test @MainActor func realWorkspaceHandlesNotInstalled() async {
        // In the test environment, ConjureDSPTerminal won't be found.
        // This exercises the "not found" path with the real implementation.
        let launcher = TerminalLauncher(workspace: WorkspaceTerminalLauncher())
        await launcher.launchIfNeeded()
        // No crash = success for this path
    }
}
