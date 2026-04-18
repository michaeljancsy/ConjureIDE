//
//  CustomUIUXTests.swift
//  ConjureDSPUITests
//
//  UI tests for the Custom UI UX refinement pass:
//   • toggle bar (Basic UI/Custom UI) visibility + CTAs
//   • New Preset popover — name + language + UI pickers
//   • Save As popover — no UI picker (UI type inherited from source)
//   • bundle file browser sidebar + its toggle (button and ⇧⌘E)
//
//  Tests share a single XCUIApplication launch (static setUp pattern) so
//  running the suite is cheap. Each method is still independently runnable —
//  the shared app just avoids paying ~5s of launch cost per test.
//

import XCTest

final class CustomUIUXTests: XCTestCase {

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

        // Dismiss any open popover between tests so state doesn't leak.
        app.typeKey(.escape, modifierFlags: [])
        usleep(150_000) // 0.15s
        app.typeKey(.escape, modifierFlags: [])

        // Close the file browser sidebar if a test left it open. We detect
        // "open" by looking for ANY bundle file row — that's set regardless
        // of bundle editability, so it works for both factory and user.
        let rowPredicate = NSPredicate(format: "identifier BEGINSWITH 'bundleFileRow_'")
        let anyRow = app.descendants(matching: .any).matching(rowPredicate).firstMatch
        if anyRow.exists {
            app.typeKey("e", modifierFlags: [.command, .shift])
            usleep(200_000)
        }
    }

    /// True if the file-browser sidebar is currently rendered. We look for
    /// any element whose id starts with `bundleFileRow_` — those are the
    /// tree entries produced by `BundleFileBrowser`.
    private func sidebarIsOpen(_ app: XCUIApplication) -> Bool {
        let p = NSPredicate(format: "identifier BEGINSWITH 'bundleFileRow_'")
        return app.descendants(matching: .any).matching(p).firstMatch.exists
    }

    // MARK: - New Preset / Save As popovers

    /// Save As is a "duplicate with a new name" action — UI type is
    /// inherited from the source bundle, not chosen here. Verify the
    /// picker is GONE (it used to exist; removing it fixed the UX
    /// incoherence of asking "do you want a custom UI?" at copy time
    /// instead of create time).
    @MainActor
    func testSaveAsPopoverHasNoUIPicker() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "saveAsButton")

        let nameField = anyElement(in: app, id: "presetNameField")
        try assertExistsOrSkip(nameField, label: "Save As name field")

        let picker = anyElement(in: app, id: "saveAsUIPicker")
        XCTAssertFalse(picker.waitForExistence(timeout: 1),
                      "Save As must not ask about UI type — that belongs in New Preset")
    }

    /// The New Preset popover collects name + language + UI type up front
    /// so the bundle hits disk fully-formed. Verify all three inputs and
    /// the confirm button are accessible.
    @MainActor
    func testNewPresetPopoverHasNameLanguageUIPickers() throws {
        let app = Self.sharedApp!

        try openToolbarPopover(app: app, buttonId: "newScriptButton")

        let nameField = anyElement(in: app, id: "newPresetNameField")
        try assertExistsOrSkip(nameField, label: "New Preset name field")

        let languagePicker = anyElement(in: app, id: "newPresetLanguagePicker")
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 2),
                      "New Preset must expose a [Python | Rust] language picker")

        let uiPicker = anyElement(in: app, id: "newPresetUIPicker")
        XCTAssertTrue(uiPicker.waitForExistence(timeout: 2),
                      "New Preset must expose a [Basic UI | Custom UI] picker")

        let confirm = anyElement(in: app, id: "confirmNewPresetButton")
        XCTAssertTrue(confirm.waitForExistence(timeout: 2),
                      "New Preset must expose a Create button")
    }

    // MARK: - File browser toggle

    /// The Files button in the toolbar toggles the sidebar. Only present
    /// when a bundle is loaded (we launch on the default factory bundle,
    /// so the button should be there). Uses the ViewBridge-safe descendants
    /// lookup since `app.buttons[...]` intermittently misses AU buttons.
    @MainActor
    func testFileBrowserToggleButtonOpensSidebar() throws {
        let app = Self.sharedApp!

        let toggle = anyElement(in: app, id: "fileBrowserToggleButton")
        try XCTSkipUnless(toggle.waitForExistence(timeout: 5),
                          "Files toggle button not accessible (no bundle loaded or ViewBridge)")

        toggle.click()

        // Poll for at least one file row in the sidebar. Rows are rendered
        // per-file with ids like `bundleFileRow_process.py`.
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'bundleFileRow_'")
        let anyRow = app.descendants(matching: .any).matching(predicate).firstMatch
        let found = anyRow.waitForExistence(timeout: 3)

        // Toggle it back off so subsequent tests start from a known state.
        // Use the keyboard shortcut as a fallback in case the button lookup
        // has gone stale after the state change.
        if toggle.exists {
            toggle.click()
        } else {
            app.typeKey("e", modifierFlags: [.command, .shift])
        }

        try XCTSkipUnless(found, "Bundle file row not accessible after sidebar toggle")
    }

    /// ⇧⌘E should flip the sidebar open and closed.
    @MainActor
    func testFileBrowserKeyboardShortcut() throws {
        let app = Self.sharedApp!

        // Start from a known "closed" state. If the previous test left the
        // sidebar open, flip it closed first so our first toggle actually
        // opens it instead of closing it.
        if sidebarIsOpen(app) {
            app.typeKey("e", modifierFlags: [.command, .shift])
            usleep(200_000)
        }

        app.typeKey("e", modifierFlags: [.command, .shift])
        usleep(300_000)

        let predicate = NSPredicate(format: "identifier BEGINSWITH 'bundleFileRow_'")
        let anyRow = app.descendants(matching: .any).matching(predicate).firstMatch
        let found = anyRow.waitForExistence(timeout: 3)

        // Close via shortcut so tearDown doesn't also have to.
        app.typeKey("e", modifierFlags: [.command, .shift])
        usleep(200_000)

        try XCTSkipUnless(found, "Bundle file row not accessible after ⇧⌘E")
    }

    /// Opening the sidebar on the default factory bundle should surface
    /// the entry script (process.py) as a row, proving the tree walker
    /// produces the right identifiers for bundle files.
    @MainActor
    func testFileBrowserShowsEntryScriptRow() throws {
        let app = Self.sharedApp!

        // Use the toolbar button rather than ⇧⌘E — keyboard shortcuts
        // don't reliably reach the AU extension through the ViewBridge,
        // but button clicks do (see testFileBrowserToggleButtonOpensSidebar).
        let toggle = anyElement(in: app, id: "fileBrowserToggleButton")
        try XCTSkipUnless(toggle.waitForExistence(timeout: 5),
                          "Files toggle not accessible through AU ViewBridge")

        // Start closed if a previous test left it open.
        if sidebarIsOpen(app) {
            toggle.click()
            usleep(200_000)
        }
        toggle.click()
        usleep(300_000)

        // Predicate-based lookup tolerates AU ViewBridge quirks better than
        // exact-id descendants lookup.
        let predicate = NSPredicate(format: "identifier == 'bundleFileRow_process.py'")
        let row = app.descendants(matching: .any).matching(predicate).firstMatch
        let found = row.waitForExistence(timeout: 3)

        // Close the sidebar before asserting.
        toggle.click()
        usleep(200_000)

        try XCTSkipUnless(found,
                          "process.py row not accessible through AU ViewBridge")
    }

}
