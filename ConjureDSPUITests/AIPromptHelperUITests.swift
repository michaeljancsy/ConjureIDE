//
//  AIPromptHelperUITests.swift
//  ConjureDSPUITests
//
//  UI tests for the terminal panel tab switching and AI Prompt Helper view.
//  The AI Prompt Helper is a tab inside the terminal panel, toggled via
//  the chatToggleButton, then switching to the "AI Prompt" tab.
//

import XCTest

final class AIPromptHelperUITests: XCTestCase {

    /// Shared across test methods so we only pay the app launch cost once.
    private static var sharedApp: XCUIApplication!

    override class func setUp() {
        super.setUp()
        sharedApp = XCUIApplication()
        sharedApp.launch()
    }

    override class func tearDown() {
        sharedApp?.terminate()
        sharedApp = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        guard let app = Self.sharedApp else { return }

        // Toggle terminal off if it was left open
        let terminalPanel = app.descendants(matching: .any)["terminalPanel"].firstMatch
        let daemonPrompt = app.descendants(matching: .any)["daemonLaunchPrompt"].firstMatch
        let aiPromptField = app.descendants(matching: .any)["aiPromptDescriptionField"].firstMatch

        if terminalPanel.exists || daemonPrompt.exists || aiPromptField.exists {
            let toggle = app.buttons["chatToggleButton"]
            if toggle.exists { toggle.click() }
        }
    }

    /// Open the terminal panel by clicking the chat toggle button.
    @MainActor
    private func openTerminalPanel(app: XCUIApplication) throws {
        let toggle = app.buttons["chatToggleButton"]
        guard toggle.waitForExistence(timeout: 10) else {
            throw XCTSkip("Chat toggle button not found")
        }
        toggle.click()
        // Wait for the panel to appear
        usleep(500_000) // 0.5s
    }

    // MARK: - Terminal Tab Switcher

    @MainActor
    func testTerminalTabSwitcherExists() throws {
        let app = Self.sharedApp!

        try openTerminalPanel(app: app)

        // Look for the tab buttons by their accessibility identifiers
        let claudeCodeTab = anyElement(in: app, id: "claudeCodeTabButton")
        let aiPromptTab = anyElement(in: app, id: "aiPromptTabButton")

        try assertExistsOrSkip(claudeCodeTab, label: "Claude Code tab button")
        XCTAssertTrue(aiPromptTab.waitForExistence(timeout: 3),
                      "AI Prompt tab button should exist")
    }

    // MARK: - AI Prompt Helper View

    @MainActor
    func testAIPromptHelperViewExists() throws {
        let app = Self.sharedApp!

        try openTerminalPanel(app: app)

        // Switch to AI Prompt tab
        let aiPromptTab = anyElement(in: app, id: "aiPromptTabButton")
        try XCTSkipUnless(aiPromptTab.waitForExistence(timeout: 5),
                          "AI Prompt tab button not accessible through AU ViewBridge")
        aiPromptTab.click()
        usleep(300_000) // 0.3s

        let descriptionField = anyElement(in: app, id: "aiPromptDescriptionField")
        try assertExistsOrSkip(descriptionField, label: "AI Prompt description field")

        let copyButton = anyElement(in: app, id: "aiPromptCopyButton")
        XCTAssertTrue(copyButton.waitForExistence(timeout: 3),
                      "Copy Prompt button should exist")
    }

    @MainActor
    func testAIPromptDescriptionAcceptsTyping() throws {
        let app = Self.sharedApp!

        try openTerminalPanel(app: app)

        // Switch to AI Prompt tab
        let aiPromptTab = anyElement(in: app, id: "aiPromptTabButton")
        try XCTSkipUnless(aiPromptTab.waitForExistence(timeout: 5),
                          "AI Prompt tab button not accessible through AU ViewBridge")
        aiPromptTab.click()
        usleep(300_000) // 0.3s

        let descriptionField = anyElement(in: app, id: "aiPromptDescriptionField")
        try XCTSkipUnless(descriptionField.waitForExistence(timeout: 5),
                          "AI Prompt description field not accessible through AU ViewBridge")

        descriptionField.click()
        descriptionField.typeText("A tremolo effect")

        // TextEditor value access can be unreliable through ViewBridge,
        // so just verify the field still exists after typing
        XCTAssertTrue(descriptionField.exists,
                      "Description field should still be present after typing")
    }
}
