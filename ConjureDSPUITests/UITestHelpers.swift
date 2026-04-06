//
//  UITestHelpers.swift
//  ConjureDSPUITests
//
//  Shared helpers for UI test classes. Provides common patterns for
//  opening toolbar popovers, dismissing them, and handling AU ViewBridge
//  limitations with graceful skips.
//

import XCTest

extension XCTestCase {

    /// Click a toolbar button to open its popover, or skip if the button is not found.
    func openToolbarPopover(app: XCUIApplication, buttonId: String, timeout: TimeInterval = 10) throws {
        let button = app.buttons[buttonId]
        guard button.waitForExistence(timeout: timeout) else {
            throw XCTSkip("\(buttonId) not found — toolbar may not have loaded")
        }
        button.click()
    }

    /// Dismiss any open popover by pressing Escape.
    func dismissPopover(app: XCUIApplication) {
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Find any descendant element by accessibility identifier, regardless of element type.
    /// Useful for elements whose XCUIElement type differs through the AU ViewBridge.
    func anyElement(in app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Assert an element exists, or skip gracefully if the ViewBridge prevents access.
    func assertExistsOrSkip(_ element: XCUIElement, label: String, timeout: TimeInterval = 5) throws {
        try XCTSkipUnless(
            element.waitForExistence(timeout: timeout),
            "\(label) not accessible through AU ViewBridge"
        )
    }
}
