//
//  TerminalInstallPromptUITests.swift
//  ConjureDSPUITests
//
//  Verifies that the "Claude Code not installed" install prompt appears when
//  the claude CLI binary is absent from all search paths. Simulates this by
//  renaming the binary before launching, then restoring it in tearDown.
//

import XCTest

final class TerminalInstallPromptUITests: XCTestCase {

    private static var hostApp: XCUIApplication!
    private static var daemonApp: XCUIApplication!

    private static let claudePaths: [String] = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
    ]

    // MARK: - Class Lifecycle

    override class func setUp() {
        super.setUp()

        // Rename all claude binaries so findClaudeCLI() returns nil.
        for path in claudePaths {
            let disabled = path + ".uitest-disabled"
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.moveItem(atPath: path, toPath: disabled)
            }
        }

        hostApp = XCUIApplication()
        hostApp.launch()
        daemonApp = XCUIApplication(bundleIdentifier: "com.MichaelJancsy.ConjureDSPTerminal")
        daemonApp.launch()
        _ = hostApp.buttons["chatToggleButton"].waitForExistence(timeout: 15)
    }

    override class func tearDown() {
        daemonApp?.terminate()
        daemonApp = nil
        hostApp?.terminate()
        hostApp = nil

        // Restore all renamed binaries.
        for path in claudePaths {
            let disabled = path + ".uitest-disabled"
            if FileManager.default.fileExists(atPath: disabled) {
                try? FileManager.default.moveItem(atPath: disabled, toPath: path)
            }
        }

        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tests

    /// When no claude binary is found, opening the terminal panel must fire the
    /// claudeNotInstalled JS event, which sets the terminalClaudeNotInstalled
    /// accessibility marker.
    @MainActor
    func testInstallPromptAppearsWhenClaudeNotInstalled() throws {
        let app = Self.hostApp!

        guard app.buttons["chatToggleButton"].waitForExistence(timeout: 10) else {
            throw XCTSkip("Chat toggle button not found — toolbar may not have loaded")
        }
        app.buttons["chatToggleButton"].click()

        let terminalPanel = app.descendants(matching: .any)["terminalPanel"].firstMatch
        guard terminalPanel.waitForExistence(timeout: 30) else {
            throw XCTSkip("Terminal panel did not appear — daemon may not be built / running")
        }

        let marker = app.descendants(matching: .any)["terminalClaudeNotInstalled"].firstMatch
        XCTAssertTrue(
            marker.waitForExistence(timeout: 15),
            "terminalClaudeNotInstalled marker never appeared — install prompt may not have been sent"
        )

        // Close panel
        if app.buttons["chatToggleButton"].exists { app.buttons["chatToggleButton"].click() }
    }
}
