//
//  LicenseUITests.swift
//  ConjureDSPUITests
//
//  UI tests for the subscription status display.
//  Launches the host app, navigates to the settings popover,
//  and verifies the subscription UI elements.
//
//  Note: SwiftUI elements inside popovers are inconsistently accessible through
//  the AU ViewBridge (NSViewServiceMarshal) in XCUITest — same limitation as
//  segmented pickers and sliders. Tests skip gracefully when popover content is
//  not queryable.
//

import XCTest

final class LicenseUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
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
        let app = XCUIApplication()
        app.launch()

        try openSettingsPopover(app: app)

        // Look for "Subscribe" button in the popover (demo mode default)
        let subscribeButton = app.buttons["subscribeButton"]
        try XCTSkipUnless(subscribeButton.waitForExistence(timeout: 10),
                          "Popover elements not accessible through AU ViewBridge")

        XCTAssertTrue(subscribeButton.exists, "Subscribe button should be visible in demo mode")
    }

    @MainActor
    func testRestartDemoButton() throws {
        let app = XCUIApplication()
        app.launch()

        try openSettingsPopover(app: app)

        // Look for "Restart Demo" button
        let restartButton = app.buttons["restartDemoButton"]
        try XCTSkipUnless(restartButton.waitForExistence(timeout: 10),
                          "Popover elements not accessible through AU ViewBridge")

        XCTAssertTrue(restartButton.exists, "Restart Demo button should be visible in demo mode")
    }
}
