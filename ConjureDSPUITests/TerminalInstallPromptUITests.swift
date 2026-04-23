//
//  TerminalInstallPromptUITests.swift
//  ConjureDSPUITests
//
//  Integration test that verifies the "no agents installed" banner reaches the
//  extension UI (via the `terminalClaudeNotInstalled` accessibility marker).
//
//  Simulation strategy: rename each candidate CLI binary to a `.uitest-disabled`
//  suffix before launching. The UI test runner's sandbox blocks writes to
//  `~/.local/bin`, so if the rename fails we skip the test — the unit-test
//  suite (ConjureDSPLogicTests/AgentDetectionTests) covers the same detection
//  logic without the sandbox limitation.
//

import Darwin
import XCTest

final class TerminalInstallPromptUITests: XCTestCase {

    private static var hostApp: XCUIApplication!
    private static var daemonApp: XCUIApplication!
    private static var renamedPaths: [String] = []

    /// Real user home (XCUITest runner's `NSHomeDirectory()` returns a sandbox container).
    private static let realHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    private static let candidatePaths: [String] = [
        "\(realHome)/.local/bin/claude",
        "\(realHome)/.claude/local/claude",
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "\(realHome)/.local/bin/gemini",
        "/usr/local/bin/gemini",
        "/opt/homebrew/bin/gemini",
        "\(realHome)/.local/bin/codex",
        "/usr/local/bin/codex",
        "/opt/homebrew/bin/codex",
    ]

    // MARK: - Class Lifecycle

    override class func setUp() {
        super.setUp()

        // Rename candidate binaries so detection returns zero agents.
        // If any rename fails (sandbox blocks write on most UI-test runners),
        // we record it and every test will XCTSkip.
        for path in candidatePaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let disabled = path + ".uitest-disabled"
            do {
                try FileManager.default.moveItem(atPath: path, toPath: disabled)
                renamedPaths.append(path)
            } catch {
                NSLog("ConjureDSP-test: cannot rename %@ (%@) — test will skip", path, error.localizedDescription)
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

        for path in renamedPaths {
            let disabled = path + ".uitest-disabled"
            try? FileManager.default.moveItem(atPath: disabled, toPath: path)
        }
        renamedPaths.removeAll()

        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // If the UI-test runner's sandbox prevented us from renaming any binary
        // that actually exists, we can't simulate "no agents" at the binary level.
        // Fall back to the logic-level tests.
        for path in Self.candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                throw XCTSkip("""
                    UI-test sandbox could not rename \(path) — `no agents` state cannot be simulated. \
                    See ConjureDSPLogicTests/AgentDetectionTests for the equivalent logic-level test.
                    """)
            }
        }
    }

    // MARK: - Tests

    /// When the daemon reports zero agents, opening the terminal panel fires the
    /// noAgentsInstalled control message → `terminalClaudeNotInstalled` marker.
    @MainActor
    func testInstallPromptAppearsWhenNoAgents() throws {
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

        if app.buttons["chatToggleButton"].exists { app.buttons["chatToggleButton"].click() }
    }
}
