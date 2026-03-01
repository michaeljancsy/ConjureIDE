//
//  TestPluginUITests.swift
//  TestPluginUITests
//
//  Created by Michael Jancsy on 2/25/26.
//

import XCTest

final class TestPluginUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testScriptEditorIsPresent() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = app.textViews["scriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10),
                      "Script editor should be visible after launch")
    }

    @MainActor
    func testSaveButtonExists() throws {
        let app = XCUIApplication()
        app.launch()
        let saveButton = app.buttons["saveButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10),
                      "Save button should be visible")
    }

    @MainActor
    func testScriptEditorShowsDefaultScript() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = app.textViews["scriptEditor"]
        guard editor.waitForExistence(timeout: 10) else {
            XCTFail("Script editor not found")
            return
        }
        let text = editor.value as? String ?? ""
        XCTAssertTrue(text.contains("def process"),
                      "Default script should contain 'def process' function definition")
    }

    @MainActor
    func testBuildIDLabelIsVisible() throws {
        let app = XCUIApplication()
        app.launch()
        let buildIDLabel = app.staticTexts["buildIDLabel"]
        XCTAssertTrue(buildIDLabel.waitForExistence(timeout: 10),
                      "Build ID label should be visible after launch")
        // Through the AU ViewBridge, SwiftUI Text content is in .value (not .label)
        let text = buildIDLabel.value as? String ?? ""
        XCTAssertTrue(text.hasPrefix("Build "),
                      "Build ID label should start with 'Build ', got '\(text)'")
        let numberStr = text.replacingOccurrences(of: "Build ", with: "")
        let number = Int(numberStr)
        XCTAssertNotNil(number, "Build ID should contain an integer, got '\(numberStr)'")
        XCTAssertGreaterThan(number!, 0, "Build ID should be positive")
    }

    @MainActor
    func testScriptEditorAcceptsTyping() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = app.textViews["scriptEditor"]
        guard editor.waitForExistence(timeout: 10) else {
            XCTFail("Script editor not found")
            return
        }

        // Click the editor to focus it, then select all and type new code
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("# test comment\ndef hello():\n    return 42\n")

        let text = editor.value as? String ?? ""
        XCTAssertTrue(text.contains("# test comment"),
                      "Typed comment should appear in editor")
        XCTAssertTrue(text.contains("def hello"),
                      "Typed function def should appear in editor")
        XCTAssertTrue(text.contains("return 42"),
                      "Typed return statement should appear in editor")
    }
}
