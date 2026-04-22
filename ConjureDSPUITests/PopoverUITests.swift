//
//  PopoverUITests.swift
//  ConjureDSPUITests
//
//  UI tests for toolbar popovers (Export, Save As, Rename),
//  the spectrogram panel toggle, and status indicators.
//

import XCTest

final class PopoverUITests: XCTestCase {

    /// Shared across test methods so we only pay the app launch cost once.
    private static var sharedApp: XCUIApplication!

    override class func setUp() {
        super.setUp()
        sharedApp = XCUIApplication()
        sharedApp.launch()
        // Wait for the AU extension to finish initializing before any test runs.
        // Without this, the extension may still be loading Python when the first
        // test queries the accessibility tree, caching AX tokens that become stale
        // once init completes and the view rebuilds.
        _ = sharedApp.buttons["saveAsButton"].waitForExistence(timeout: 15)
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

        // Dismiss any open popover
        app.typeKey(.escape, modifierFlags: [])

        // Toggle spectrogram off if it was left open
        let spectrogramPanel = app.descendants(matching: .any)["spectrogramSidePanel"].firstMatch
        if spectrogramPanel.exists {
            let toggle = app.buttons["spectrogramToggleButton"]
            if toggle.exists { toggle.click() }
        }
    }

    // MARK: - Export Popover

    @MainActor
    func testExportPopoverOpensAndHasFields() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "exportButton")

        let nameField = anyElement(in: app, id: "exportNameField")
        try assertExistsOrSkip(nameField, label: "Export name field")

        let exportButton = anyElement(in: app, id: "confirmExportButton")
        XCTAssertTrue(exportButton.waitForExistence(timeout: 3),
                      "Confirm Export button should exist")
    }

    // MARK: - Save As Popover

    @MainActor
    func testSaveAsPopoverOpensAndHasFields() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "saveAsButton")

        let nameField = anyElement(in: app, id: "presetNameField")
        try assertExistsOrSkip(nameField, label: "Preset name field")

        let saveButton = anyElement(in: app, id: "confirmSaveButton")
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3),
                      "Confirm Save button should exist")
    }

    @MainActor
    func testSaveAsFieldAcceptsTyping() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "saveAsButton")

        let nameField = anyElement(in: app, id: "presetNameField")
        try XCTSkipUnless(nameField.waitForExistence(timeout: 5),
                          "Preset name field not accessible through AU ViewBridge")

        // Select all existing text and type new text
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("Test Preset Name")

        // Verify value was accepted (field should contain our text)
        let fieldValue = nameField.value as? String ?? ""
        XCTAssertTrue(fieldValue.contains("Test Preset Name"),
                      "Name field should contain typed text, got: \(fieldValue)")
    }

    // MARK: - Rename Popover

    @MainActor
    func testRenamePopoverOpensAndHasFields() throws {
        let app = Self.sharedApp!

        // Rename button only visible for user/repo presets
        let renameButton = app.buttons["renamePresetButton"]
        try XCTSkipUnless(renameButton.waitForExistence(timeout: 5),
                          "Rename button not visible — likely on a factory preset")
        renameButton.click()

        let nameField = anyElement(in: app, id: "renamePresetField")
        try assertExistsOrSkip(nameField, label: "Rename preset field")

        let confirmButton = anyElement(in: app, id: "confirmRenameButton")
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 3),
                      "Confirm Rename button should exist")
    }

    // MARK: - Spectrogram Panel

    @MainActor
    func testSpectrogramTogglesCorrectly() throws {
        let app = Self.sharedApp!

        let toggleButton = app.buttons["spectrogramToggleButton"]
        guard toggleButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("Spectrogram toggle button not found")
        }

        let panel = app.descendants(matching: .any)["spectrogramSidePanel"].firstMatch

        // Toggle ON
        toggleButton.click()
        XCTAssertTrue(panel.waitForExistence(timeout: 3),
                      "Spectrogram panel should appear after toggling on")

        // Toggle OFF
        toggleButton.click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3),
                      "Spectrogram panel should disappear after toggling off")
    }

    // MARK: - Status Indicators

    @MainActor
    func testDemoExpiredOverlayNotShownByDefault() throws {
        let app = Self.sharedApp!

        let overlay = app.descendants(matching: .any)["demoExpiredOverlay"].firstMatch
        // Give the app a moment to settle, then verify the overlay is NOT present.
        // The demo timer starts fresh on each launch, so it should not be expired.
        usleep(500_000) // 0.5s
        XCTAssertFalse(overlay.exists,
                       "Demo expired overlay should not be shown on fresh launch")
    }
}
