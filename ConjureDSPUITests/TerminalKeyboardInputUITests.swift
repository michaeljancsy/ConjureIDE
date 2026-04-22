//
//  TerminalKeyboardInputUITests.swift
//  ConjureDSPUITests
//
//  End-to-end regression test for the terminal keyboard input pathway.
//  Opens the terminal panel, types text WITHOUT clicking inside the
//  terminal first, and waits for the hidden `terminalFirstInputReceived`
//  accessibility marker to appear — which is flipped on by the
//  TerminalView coordinator when the JS bridge reports that a keystroke
//  reached the WebSocket.
//
//  If focus is routed to xterm's hidden textarea (the pre-fix state),
//  keystrokes get silently dropped by the AU ViewBridge and the marker
//  never appears.
//

import XCTest

final class TerminalKeyboardInputUITests: XCTestCase {

    private static var hostApp: XCUIApplication!
    private static var daemonApp: XCUIApplication!

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

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Regression test: on a fresh terminal connection, typing immediately
    /// (without clicking inside the terminal) must reach the PTY. Validates
    /// that focus lands on the contentEditable `#input-proxy` and not
    /// xterm's hidden textarea — which would silently drop input under the
    /// AU ViewBridge (see TerminalBridgeFocusTests for the unit-level check).
    @MainActor
    func testKeyboardInputReachesTerminalWithoutClicking() throws {
        let app = Self.hostApp!
        Self.daemonApp.launch()

        // Open the terminal panel
        let toggle = app.buttons["chatToggleButton"]
        guard toggle.waitForExistence(timeout: 10) else {
            throw XCTSkip("Chat toggle button not found — toolbar may not have loaded")
        }
        toggle.click()

        let terminalPanel = app.descendants(matching: .any)["terminalPanel"].firstMatch
        guard terminalPanel.waitForExistence(timeout: 30) else {
            throw XCTSkip("Terminal panel did not appear — daemon may not be built / running")
        }

        // Intentionally DO NOT click inside the terminal — the whole point of
        // this test is to validate that typing works on a fresh connection
        // without requiring the mousedown-focuses-inputProxy fallback.
        //
        // Give the WebSocket a moment to connect and run socket.onopen, which
        // is where focus is established.
        let marker = app.descendants(matching: .any)["terminalFirstInputReceived"].firstMatch

        // Type a single character. XCUIApplication.typeText delivers keystrokes
        // to the app the same way a real keyboard would, so this exercises the
        // AU ViewBridge / NSTextInputClient pathway that was dropping input.
        //
        // Retry a few times because the socket + focus handshake can take a
        // couple of seconds after the panel appears.
        var typed = false
        for _ in 0..<10 {
            if marker.waitForExistence(timeout: 1) { break }
            app.typeText("a")
            typed = true
        }

        XCTAssertTrue(typed, "expected to type at least once")
        XCTAssertTrue(
            marker.waitForExistence(timeout: 5),
            "Keyboard input never reached the terminal — focus is likely on xterm's textarea rather than #input-proxy"
        )

        // Close panel to leave a clean state for other tests
        if toggle.exists { toggle.click() }
    }
}
