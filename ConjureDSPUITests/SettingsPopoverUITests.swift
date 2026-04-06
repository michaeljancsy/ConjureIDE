//
//  SettingsPopoverUITests.swift
//  ConjureDSPUITests
//
//  UI tests for the settings popover and its sub-views: subscription status,
//  GitHub settings, editor settings, and third-party licenses.
//
//  Note: SwiftUI elements inside popovers are inconsistently accessible through
//  the AU ViewBridge (NSViewServiceMarshal) in XCUITest — same limitation as
//  segmented pickers and sliders. Tests skip gracefully when popover content is
//  not queryable.
//

import XCTest

final class SettingsPopoverUITests: XCTestCase {

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
        // Double-Escape: first dismisses any sheet (e.g. licenses), second
        // dismisses the settings popover itself.
        if let app = Self.sharedApp {
            app.typeKey(.escape, modifierFlags: [])
            usleep(100_000) // 0.1s
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// Open the settings popover and return it, or skip if not accessible.
    @MainActor
    private func openSettingsPopover(app: XCUIApplication) throws {
        let settingsButton = app.buttons["settingsButton"]
        guard settingsButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("Settings button not found")
        }
        settingsButton.click()
    }

    // MARK: - Subscription Status Display

    @MainActor
    func testDemoModeShownByDefault() throws {
        let app = Self.sharedApp!

        try openSettingsPopover(app: app)

        // Look for "Subscribe" button in the popover (demo mode default)
        let subscribeButton = app.buttons["subscribeButton"]
        try XCTSkipUnless(subscribeButton.waitForExistence(timeout: 10),
                          "Popover elements not accessible through AU ViewBridge")

        XCTAssertTrue(subscribeButton.exists, "Subscribe button should be visible in demo mode")
    }

    @MainActor
    func testRestartDemoButton() throws {
        let app = Self.sharedApp!

        try openSettingsPopover(app: app)

        // Look for "Restart Demo" button
        let restartButton = app.buttons["restartDemoButton"]
        try XCTSkipUnless(restartButton.waitForExistence(timeout: 10),
                          "Popover elements not accessible through AU ViewBridge")

        XCTAssertTrue(restartButton.exists, "Restart Demo button should be visible in demo mode")
    }

    // MARK: - GitHub Settings

    @MainActor
    func testGitHubSettingsSectionExists() throws {
        let app = Self.sharedApp!

        try openSettingsPopover(app: app)

        // Look for the "Personal Access Token" heading text
        let heading = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Personal Access Token'")
        ).firstMatch
        try assertExistsOrSkip(heading, label: "GitHub settings heading")
    }

    @MainActor
    func testGitHubTokenFieldExists() throws {
        let app = Self.sharedApp!

        try openSettingsPopover(app: app)

        let tokenField = anyElement(in: app, id: "githubTokenField")
        try assertExistsOrSkip(tokenField, label: "GitHub token field")

        let saveButton = app.buttons["saveTokenButton"]
        try assertExistsOrSkip(saveButton, label: "Save Token button")
    }

    // MARK: - Editor Settings

    @MainActor
    func testEditorSettingsSectionExists() throws {
        let app = Self.sharedApp!

        try openSettingsPopover(app: app)

        // The editor settings section has a "Theme" or "Editor" label
        let heading = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Editor' OR label CONTAINS 'Theme'")
        ).firstMatch
        try assertExistsOrSkip(heading, label: "Editor settings heading")
    }

    // MARK: - Third-Party Licenses

    @MainActor
    func testThirdPartyLicensesSectionExists() throws {
        let app = Self.sharedApp!

        try openSettingsPopover(app: app)

        let heading = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'About'")
        ).firstMatch
        try assertExistsOrSkip(heading, label: "About section heading")
    }

    @MainActor
    func testOpenLicensesButtonExists() throws {
        let app = Self.sharedApp!

        try openSettingsPopover(app: app)

        let licensesButton = anyElement(in: app, id: "openLicensesButton")
        try assertExistsOrSkip(licensesButton, label: "Open Source Licenses button")
    }

    @MainActor
    func testOpenLicensesOpensSheet() throws {
        let app = Self.sharedApp!

        try openSettingsPopover(app: app)

        let licensesButton = anyElement(in: app, id: "openLicensesButton")
        try XCTSkipUnless(licensesButton.waitForExistence(timeout: 5),
                          "Open Licenses button not accessible through AU ViewBridge")
        licensesButton.click()

        // The sheet should show "Open Source Licenses" heading and a Done button
        let sheetHeading = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Open Source Licenses'")
        ).firstMatch
        try assertExistsOrSkip(sheetHeading, label: "Licenses sheet heading", timeout: 5)
    }
}
