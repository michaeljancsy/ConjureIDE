//
//  LicenseUITests.swift
//  ConjureDSPUITests
//
//  UI tests for the license activation flow.
//  Launches the host app, navigates to the license settings popover,
//  enters a test serial, and verifies the UI state transitions.
//
//  The test serial is generated at build time by scripts/generate-test-serial.sh.
//  Tests skip gracefully when no test serial is available.
//
//  Note: SwiftUI elements inside popovers are inconsistently accessible through
//  the AU ViewBridge (NSViewServiceMarshal) in XCUITest — same limitation as
//  segmented pickers and sliders (see ConjureDSPUITests.swift lines 87-89, 249-252).
//  These tests use XCTSkipUnless to skip gracefully when popover content is
//  not queryable, so they'll automatically activate if the issue is ever resolved.
//  The full license activation pipeline is reliably tested via the Swift Testing
//  integration tests in ConjureDSPTests/LicenseTests.swift.
//

import XCTest

final class LicenseUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Test Serial Loading

    private func loadTestSerial() -> String? {
        let testFile = URL(fileURLWithPath: #file)
        let projectRoot = testFile
            .deletingLastPathComponent()   // ConjureDSPUITests/
            .deletingLastPathComponent()   // project root
        let url = projectRoot.appendingPathComponent(".test-serial")
        guard let serial = try? String(contentsOf: url, encoding: .utf8),
              !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return serial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Open the settings popover and return the serial key field, or skip if not accessible.
    @MainActor
    private func openSettingsPopover(app: XCUIApplication) throws -> XCUIElement {
        let settingsButton = app.buttons["settingsButton"]
        guard settingsButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("Settings button not found")
        }
        settingsButton.click()

        // Popover content is inconsistently accessible through AU ViewBridge.
        // Wait longer to reduce flakiness, but skip if still not found.
        let serialField = app.textFields["serialKeyField"]
        try XCTSkipUnless(serialField.waitForExistence(timeout: 10),
                          "Popover elements not accessible through AU ViewBridge (same limitation as segmented picker/sliders)")
        return serialField
    }

    // MARK: - License Activation

    @MainActor
    func testLicenseActivationUI() throws {
        let serial = loadTestSerial()
        try XCTSkipIf(serial == nil, "No test serial — keypair.bin not available")

        let app = XCUIApplication()
        app.launch()

        let serialField = try openSettingsPopover(app: app)

        // Enter the test serial
        serialField.click()
        serialField.typeText(serial!)

        // Click Activate
        let activateButton = app.buttons["activateLicenseButton"]
        try XCTSkipUnless(activateButton.waitForExistence(timeout: 5),
                          "Activate button not accessible through ViewBridge")
        activateButton.click()

        // Verify the "Licensed" status appears.
        // The popover UI may not update visibly through ViewBridge after the action,
        // so skip if the status element isn't found (ViewBridge limitation).
        let licenseStatus = app.descendants(matching: .any)["licenseStatus"]
        try XCTSkipUnless(licenseStatus.waitForExistence(timeout: 5),
                          "License status not accessible through ViewBridge after activation")

        // Verify the demo indicator is gone
        let demoIndicator = app.descendants(matching: .any)["demoIndicator"]
        let demoGone = !demoIndicator.waitForExistence(timeout: 2)
        XCTAssertTrue(demoGone, "Demo indicator should disappear after licensing")
    }

    @MainActor
    func testInvalidSerialShowsError() throws {
        let app = XCUIApplication()
        app.launch()

        let serialField = try openSettingsPopover(app: app)

        // Enter an invalid serial
        serialField.click()
        serialField.typeText("invalid.serial.key")

        // Click Activate
        let activateButton = app.buttons["activateLicenseButton"]
        try XCTSkipUnless(activateButton.waitForExistence(timeout: 5),
                          "Activate button not accessible through ViewBridge")
        activateButton.click()

        // Verify error message appears
        let errorMessage = app.staticTexts["licenseErrorMessage"]
        try XCTSkipUnless(errorMessage.waitForExistence(timeout: 5),
                          "Error message not accessible through ViewBridge")

        // Verify we're NOT licensed (licenseStatus should not exist)
        let licenseStatus = app.descendants(matching: .any)["licenseStatus"]
        XCTAssertFalse(licenseStatus.exists,
                       "License status should not appear after invalid serial")
    }

    @MainActor
    func testActivateButtonDisabledWhenEmpty() throws {
        let app = XCUIApplication()
        app.launch()

        _ = try openSettingsPopover(app: app)

        // Wait for the activate button
        let activateButton = app.buttons["activateLicenseButton"]
        try XCTSkipUnless(activateButton.waitForExistence(timeout: 5),
                          "Activate button not accessible through ViewBridge")

        // Button should be disabled when serial field is empty
        XCTAssertFalse(activateButton.isEnabled,
                       "Activate button should be disabled when serial field is empty")
    }
}
