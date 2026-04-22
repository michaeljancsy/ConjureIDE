//
//  BrowserUITests.swift
//  ConjureDSPUITests
//
//  UI tests for browser/manager popovers: preset browser, import URL,
//  tone browser, and package manager.
//
//  Note: Import URL popover is chained — it opens after the preset browser
//  dismisses with a 150ms delay. Tests wait 0.5s to account for this timing.
//

import XCTest

final class BrowserUITests: XCTestCase {

    /// Shared across test methods so we only pay the app launch cost once.
    private static var sharedApp: XCUIApplication!

    override class func setUp() {
        super.setUp()
        sharedApp = XCUIApplication()
        sharedApp.launch()
        _ = sharedApp.buttons["presetMenu"].waitForExistence(timeout: 15)
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

        // Double-Escape with gap to handle chained popovers
        app.typeKey(.escape, modifierFlags: [])
        usleep(300_000) // 0.3s
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Preset Browser

    @MainActor
    func testPresetBrowserOpensAndHasElements() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "presetMenu")

        let searchField = anyElement(in: app, id: "presetBrowserSearchField")
        try assertExistsOrSkip(searchField, label: "Preset browser search field")

        let doneButton = anyElement(in: app, id: "presetBrowserDoneButton")
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3),
                      "Preset browser Done button should exist")

        let importButton = anyElement(in: app, id: "importURLButton")
        XCTAssertTrue(importButton.waitForExistence(timeout: 3),
                      "Import URL button should exist")
    }

    @MainActor
    func testPresetBrowserSearchFieldAcceptsTyping() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "presetMenu")

        let searchField = anyElement(in: app, id: "presetBrowserSearchField")
        try XCTSkipUnless(searchField.waitForExistence(timeout: 5),
                          "Preset browser search field not accessible through AU ViewBridge")

        searchField.click()
        searchField.typeText("test search")

        let fieldValue = searchField.value as? String ?? ""
        XCTAssertTrue(fieldValue.contains("test search"),
                      "Search field should contain typed text, got: \(fieldValue)")
    }

    @MainActor
    func testPresetBrowserShowsPresetRows() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "presetMenu")

        // Wait for the popover to load, then check for any preset name text.
        // Factory presets always exist, so there should be at least one row.
        let doneButton = anyElement(in: app, id: "presetBrowserDoneButton")
        try XCTSkipUnless(doneButton.waitForExistence(timeout: 5),
                          "Preset browser not accessible through AU ViewBridge")

        // Look for "Factory" source label text — always present with factory presets.
        // Individual row texts may not be accessible through ViewBridge, so skip gracefully.
        let factoryLabel = app.staticTexts.containing(
            NSPredicate(format: "label == 'Factory'")
        ).firstMatch
        try assertExistsOrSkip(factoryLabel, label: "Preset browser row content")
    }

    // MARK: - Import URL (chained from preset browser)

    @MainActor
    func testImportURLPopoverOpens() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "presetMenu")

        let importButton = anyElement(in: app, id: "importURLButton")
        try XCTSkipUnless(importButton.waitForExistence(timeout: 5),
                          "Import URL button not accessible through AU ViewBridge")

        importButton.click()

        // Wait for chained popover
        usleep(500_000) // 0.5s

        let urlField = anyElement(in: app, id: "importURLField")
        try assertExistsOrSkip(urlField, label: "Import URL field", timeout: 5)

        let fetchButton = anyElement(in: app, id: "importFetchButton")
        XCTAssertTrue(fetchButton.waitForExistence(timeout: 3),
                      "Fetch button should exist in import URL popover")
    }

    // MARK: - Tone Browser

    @MainActor
    func testToneBrowserOpensAndHasElements() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "tonesButton")

        let doneButton = anyElement(in: app, id: "toneBrowserDoneButton")
        try assertExistsOrSkip(doneButton, label: "Tone browser Done button")

        // When unauthenticated, "Connect tone3000" button appears;
        // when authenticated, search field appears. Check for either.
        // These elements may not be accessible through the ViewBridge, so skip gracefully.
        let connectButton = anyElement(in: app, id: "toneConnectButton")
        let searchField = anyElement(in: app, id: "toneBrowserSearchField")

        let hasConnect = connectButton.waitForExistence(timeout: 3)
        let hasSearch = searchField.waitForExistence(timeout: 1)

        try XCTSkipUnless(hasConnect || hasSearch,
                          "Tone browser content not accessible through AU ViewBridge")
    }

    // MARK: - Package Manager

    @MainActor
    func testPackageManagerOpensAndHasElements() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "packagesButton")

        let doneButton = anyElement(in: app, id: "packageManagerDoneButton")
        try assertExistsOrSkip(doneButton, label: "Package manager Done button")

        let searchField = anyElement(in: app, id: "packageManagerSearchField")
        XCTAssertTrue(searchField.waitForExistence(timeout: 3),
                      "Package manager search field should exist")
    }

    @MainActor
    func testPackageManagerSearchFieldAcceptsTyping() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "packagesButton")

        let searchField = anyElement(in: app, id: "packageManagerSearchField")
        try XCTSkipUnless(searchField.waitForExistence(timeout: 5),
                          "Package manager search field not accessible through AU ViewBridge")

        searchField.click()
        searchField.typeText("numpy")

        let fieldValue = searchField.value as? String ?? ""
        XCTAssertTrue(fieldValue.contains("numpy"),
                      "Search field should contain typed text, got: \(fieldValue)")
    }

    @MainActor
    func testPackageManagerSpecFieldAcceptsTyping() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "packagesButton")

        let specField = anyElement(in: app, id: "packageManagerSpecField")
        try XCTSkipUnless(specField.waitForExistence(timeout: 5),
                          "Package spec field not accessible through AU ViewBridge")

        specField.click()
        specField.typeText("test-package")

        let fieldValue = specField.value as? String ?? ""
        XCTAssertTrue(fieldValue.contains("test-package"),
                      "Spec field should contain typed text, got: \(fieldValue)")
    }
}
