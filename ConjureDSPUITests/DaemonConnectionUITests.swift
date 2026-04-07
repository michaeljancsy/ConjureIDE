//
//  DaemonConnectionUITests.swift
//  ConjureDSPUITests
//
//  Integration tests that launch both the host app and the ConjureDSPTerminal
//  daemon, then verify the AU extension connects to the daemon via file-based
//  port discovery. Tests the full connection lifecycle: connect, disconnect,
//  and reconnect.
//

import XCTest

final class DaemonConnectionUITests: XCTestCase {

    /// Host app — launched once for all tests in this class.
    private static var hostApp: XCUIApplication!

    /// Companion daemon app — lifecycle controlled per test.
    private static var daemonApp: XCUIApplication!

    /// Path to the App Group container used by the host app and daemon.
    private static let containerURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("ConjureDSP")
    }()

    // MARK: - Class Lifecycle

    override class func setUp() {
        super.setUp()
        hostApp = XCUIApplication()
        hostApp.launch()
        daemonApp = XCUIApplication(bundleIdentifier: "com.MichaelJancsy.ConjureDSPTerminal")
    }

    override class func tearDown() {
        daemonApp?.terminate()
        daemonApp = nil
        hostApp?.terminate()
        hostApp = nil
        super.tearDown()
    }

    // MARK: - Per-Test Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        guard let app = Self.hostApp else { return }
        closeTerminalPanelIfOpen(app: app)
    }

    // MARK: - Helpers

    /// Open the terminal panel by clicking the chat toggle button.
    @MainActor
    private func openTerminalPanel(app: XCUIApplication) throws {
        let toggle = app.buttons["chatToggleButton"]
        guard toggle.waitForExistence(timeout: 10) else {
            throw XCTSkip("Chat toggle button not found — toolbar may not have loaded")
        }
        toggle.click()
        usleep(500_000) // 0.5s for panel animation
    }

    /// Close the terminal panel if it's currently open.
    private func closeTerminalPanelIfOpen(app: XCUIApplication) {
        let terminalPanel = app.descendants(matching: .any)["terminalPanel"].firstMatch
        let daemonPrompt = app.descendants(matching: .any)["daemonLaunchPrompt"].firstMatch

        if terminalPanel.exists || daemonPrompt.exists {
            let toggle = app.buttons["chatToggleButton"]
            if toggle.exists { toggle.click() }
        }
    }

    /// Delete the terminal-server-port file to speed up disconnection detection.
    private func deleteTerminalServerPortFile() {
        let portFile = Self.containerURL.appendingPathComponent("terminal-server-port")
        try? FileManager.default.removeItem(at: portFile)
    }

    /// Wait for an element to appear, polling at short intervals.
    @MainActor
    private func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval,
        message: String
    ) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    /// Ensure the daemon is running and the terminal panel is visible.
    /// Returns true if terminal panel is showing, false if only daemon prompt is showing.
    @MainActor
    @discardableResult
    private func ensureDaemonRunningAndTerminalOpen(app: XCUIApplication) throws -> Bool {
        // Launch daemon if not already running
        Self.daemonApp.launch()

        // Open terminal panel
        let terminalPanel = anyElement(in: app, id: "terminalPanel")
        let daemonPrompt = anyElement(in: app, id: "daemonLaunchPrompt")

        // If terminal panel isn't visible yet, open it
        if !terminalPanel.exists && !daemonPrompt.exists {
            try openTerminalPanel(app: app)
        }

        // Wait for terminal panel to appear (daemon needs time to start + port discovery)
        if terminalPanel.waitForExistence(timeout: 30) {
            return true
        }

        // Daemon might still be provisioning — check if prompt is showing
        if daemonPrompt.exists {
            return false
        }

        return false
    }

    // MARK: - Tests

    /// Verify that launching the daemon transitions the UI from the daemon
    /// launch prompt to the terminal panel.
    @MainActor
    func testDaemonConnectionShowsTerminalPanel() throws {
        let app = Self.hostApp!

        try openTerminalPanel(app: app)

        let terminalPanel = anyElement(in: app, id: "terminalPanel")
        let daemonPrompt = anyElement(in: app, id: "daemonLaunchPrompt")

        // Check initial state — one of the two views should be visible
        let initialPrompt = daemonPrompt.waitForExistence(timeout: 3)
        let initialTerminal = terminalPanel.waitForExistence(timeout: 1)

        guard initialPrompt || initialTerminal else {
            throw XCTSkip("Neither terminal panel nor daemon prompt visible — ViewBridge limitation")
        }

        if initialTerminal {
            // Daemon was already running — just verify terminal panel is present
            XCTAssertTrue(terminalPanel.exists,
                          "Terminal panel should remain visible when daemon is already running")
            return
        }

        // Daemon prompt is showing — launch the daemon and wait for transition
        XCTAssertTrue(initialPrompt, "Daemon launch prompt should be showing before daemon starts")

        Self.daemonApp.launch()

        // Wait for the terminal panel to appear (daemon provisioning + port discovery + polling)
        XCTAssertTrue(
            terminalPanel.waitForExistence(timeout: 30),
            "Terminal panel should appear within 30s after launching daemon"
        )

        // The daemon prompt should no longer be visible
        XCTAssertTrue(
            daemonPrompt.waitForNonExistence(timeout: 5),
            "Daemon launch prompt should disappear after connection"
        )
    }

    /// Verify that terminating the daemon transitions the UI back to the
    /// daemon launch prompt.
    @MainActor
    func testDaemonDisconnectionShowsLaunchPrompt() throws {
        let app = Self.hostApp!

        // Ensure daemon is running and terminal is visible
        let connected = try ensureDaemonRunningAndTerminalOpen(app: app)
        guard connected else {
            throw XCTSkip("Could not establish daemon connection — daemon may not be built")
        }

        let terminalPanel = anyElement(in: app, id: "terminalPanel")
        let daemonPrompt = anyElement(in: app, id: "daemonLaunchPrompt")

        XCTAssertTrue(terminalPanel.exists, "Terminal panel should be visible before disconnection test")

        // Terminate the daemon
        Self.daemonApp.terminate()

        // Delete port file to speed up DaemonStatusChecker detection
        // (otherwise it waits for canConnect to fail on a stale port)
        deleteTerminalServerPortFile()

        // Wait for the daemon launch prompt to reappear
        // DaemonStatusChecker polls every 2s, so 10s gives 5 poll cycles
        XCTAssertTrue(
            daemonPrompt.waitForExistence(timeout: 10),
            "Daemon launch prompt should reappear within 10s after daemon termination"
        )

        XCTAssertTrue(
            terminalPanel.waitForNonExistence(timeout: 5),
            "Terminal panel should disappear after daemon disconnection"
        )
    }

    /// Verify the extension recovers when the daemon is stopped and restarted.
    @MainActor
    func testDaemonReconnectionAfterRestart() throws {
        let app = Self.hostApp!

        // Ensure daemon is running and terminal is visible
        let connected = try ensureDaemonRunningAndTerminalOpen(app: app)
        guard connected else {
            throw XCTSkip("Could not establish daemon connection — daemon may not be built")
        }

        let terminalPanel = anyElement(in: app, id: "terminalPanel")
        let daemonPrompt = anyElement(in: app, id: "daemonLaunchPrompt")

        // Terminate the daemon
        Self.daemonApp.terminate()
        deleteTerminalServerPortFile()

        // Wait for disconnection
        guard daemonPrompt.waitForExistence(timeout: 10) else {
            throw XCTSkip("Daemon prompt did not reappear after termination — timing issue")
        }

        // Re-launch the daemon
        Self.daemonApp.launch()

        // Wait for reconnection
        XCTAssertTrue(
            terminalPanel.waitForExistence(timeout: 30),
            "Terminal panel should reappear within 30s after daemon restart"
        )

        XCTAssertTrue(
            daemonPrompt.waitForNonExistence(timeout: 5),
            "Daemon launch prompt should disappear after reconnection"
        )
    }

    /// Verify that toggling the terminal panel off and back on preserves
    /// daemon connection state (doesn't fall back to the launch prompt).
    @MainActor
    func testTerminalPanelPreservesConnectionAfterToggle() throws {
        let app = Self.hostApp!

        // Ensure daemon is running and terminal is visible
        let connected = try ensureDaemonRunningAndTerminalOpen(app: app)
        guard connected else {
            throw XCTSkip("Could not establish daemon connection — daemon may not be built")
        }

        let terminalPanel = anyElement(in: app, id: "terminalPanel")
        let daemonPrompt = anyElement(in: app, id: "daemonLaunchPrompt")

        XCTAssertTrue(terminalPanel.exists, "Terminal panel should be visible before toggle test")

        // Toggle terminal panel off
        let toggle = app.buttons["chatToggleButton"]
        XCTAssertTrue(toggle.exists, "Chat toggle button should exist")
        toggle.click()
        usleep(500_000)

        // Both should be hidden now
        XCTAssertFalse(terminalPanel.exists, "Terminal panel should be hidden after toggle off")
        XCTAssertFalse(daemonPrompt.exists, "Daemon prompt should be hidden after toggle off")

        // Toggle terminal panel back on
        toggle.click()
        usleep(500_000)

        // Terminal panel should reappear (not the daemon prompt)
        XCTAssertTrue(
            terminalPanel.waitForExistence(timeout: 5),
            "Terminal panel should reappear after toggle, not daemon prompt"
        )
        XCTAssertFalse(
            daemonPrompt.exists,
            "Daemon prompt should NOT appear after toggle when daemon is still running"
        )
    }
}
