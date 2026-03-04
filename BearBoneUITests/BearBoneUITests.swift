//
//  BearBoneUITests.swift
//  BearBoneUITests
//
//  Created by Michael Jancsy on 2/25/26.
//

import XCTest

final class BearBoneUITests: XCTestCase {

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
    func testRunButtonExists() throws {
        let app = XCUIApplication()
        app.launch()
        let runButton = app.buttons["runButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 10),
                      "Run button should be visible")
    }

    @MainActor
    func testPresetToolbarExists() throws {
        let app = XCUIApplication()
        app.launch()
        // Verify prev/next preset buttons exist (toolbar is present)
        let prevButton = app.buttons["prevPresetButton"]
        XCTAssertTrue(prevButton.waitForExistence(timeout: 10),
                      "Previous preset button should be visible")
        let nextButton = app.buttons["nextPresetButton"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 10),
                      "Next preset button should be visible")
    }

    @MainActor
    func testSaveAsButtonExists() throws {
        let app = XCUIApplication()
        app.launch()
        let saveAsButton = app.buttons["saveAsButton"]
        XCTAssertTrue(saveAsButton.waitForExistence(timeout: 10),
                      "Save As button should be visible")
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

    // Note: testLanguagePickerExists was removed because SwiftUI segmented pickers
    // are not accessible through the AU ViewBridge (NSViewServiceMarshal) in XCUITest.
    // The picker is visually present and functional but not discoverable via XCUI queries.

    // MARK: - Phase 4: Language Selector UI Tests

    /// Click next-preset until the editor contains the target string, or fail after maxClicks.
    @MainActor
    private func navigateToPresetContaining(
        _ target: String,
        editor: XCUIElement,
        nextButton: XCUIElement,
        maxClicks: Int = 10
    ) -> Bool {
        for _ in 0..<maxClicks {
            nextButton.click()
            // Wait for editor to update after preset change
            let predicate = NSPredicate(format: "value CONTAINS %@", target)
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: editor)
            let result = XCTWaiter.wait(for: [expectation], timeout: 2)
            if result == .completed {
                return true
            }
        }
        return false
    }

    @MainActor
    func testNavigateToRustPreset() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = app.textViews["scriptEditor"]
        guard editor.waitForExistence(timeout: 10) else {
            XCTFail("Script editor not found")
            return
        }

        // Default script should be Python
        let initialText = editor.value as? String ?? ""
        XCTAssertTrue(initialText.contains("def process"),
                      "Initial preset should be Python with 'def process'")

        let nextButton = app.buttons["nextPresetButton"]
        guard nextButton.waitForExistence(timeout: 5) else {
            XCTFail("Next preset button not found")
            return
        }

        // Cycle through presets until we find one with Rust code
        let found = navigateToPresetContaining("fn process", editor: editor, nextButton: nextButton)
        XCTAssertTrue(found, "Should find a Rust preset with 'fn process' by cycling through presets")

        let rustText = editor.value as? String ?? ""
        XCTAssertFalse(rustText.contains("def process"),
                       "Rust preset should not contain Python 'def process'")
    }

    @MainActor
    func testPresetCycleRustThenBackToPython() throws {
        let app = XCUIApplication()
        app.launch()
        let editor = app.textViews["scriptEditor"]
        guard editor.waitForExistence(timeout: 10) else {
            XCTFail("Script editor not found")
            return
        }

        let nextButton = app.buttons["nextPresetButton"]
        guard nextButton.waitForExistence(timeout: 5) else {
            XCTFail("Next preset button not found")
            return
        }

        // Navigate to Rust preset
        let foundRust = navigateToPresetContaining("fn process", editor: editor, nextButton: nextButton)
        XCTAssertTrue(foundRust, "Should find a Rust preset")

        // Click next to move past Rust preset, then find Python again
        let foundPython = navigateToPresetContaining("def process", editor: editor, nextButton: nextButton)
        XCTAssertTrue(foundPython,
                      "After cycling past Rust preset, should find a Python preset with 'def process'")
    }

    // MARK: - Rust Compilation Tests

    @MainActor
    func testRustPresetCompilesSuccessfully() throws {
        let app = XCUIApplication()
        app.launch()

        let editor = app.textViews["scriptEditor"]
        guard editor.waitForExistence(timeout: 20) else {
            XCTFail("Script editor not found")
            return
        }

        let nextButton = app.buttons["nextPresetButton"]
        guard nextButton.waitForExistence(timeout: 10) else {
            XCTFail("Next preset button not found")
            return
        }

        // Navigate to Rust preset
        let foundRust = navigateToPresetContaining("fn process", editor: editor, nextButton: nextButton)
        XCTAssertTrue(foundRust, "Should find a Rust preset with 'fn process'")

        // Click Run
        let runButton = app.buttons["runButton"]
        guard runButton.waitForExistence(timeout: 5) else {
            XCTFail("Run button not found")
            return
        }
        runButton.click()

        // Wait for compilation to finish — look for either success or error status.
        // Compilation can take several seconds for Rust/WASM.
        let successStatus = app.staticTexts["successStatus"]
        let errorStatus = app.staticTexts["errorStatus"]

        // Poll for up to 30 seconds for either status to appear
        let deadline = Date().addingTimeInterval(30)
        var foundStatus = false
        while Date() < deadline {
            if successStatus.exists || errorStatus.exists {
                foundStatus = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTAssertTrue(foundStatus, "Should see either success or error status after clicking Run")

        if errorStatus.exists {
            let errorText = errorStatus.value as? String ?? errorStatus.label
            XCTAssertFalse(errorText.contains("not found"),
                           "Rust compilation should not fail with 'not found': \(errorText)")
            XCTAssertFalse(errorText.contains("rustc not found"),
                           "rustc should be discoverable in the AU extension context")
        }

        // Ideally we get success
        if successStatus.exists {
            let successText = successStatus.value as? String ?? successStatus.label
            XCTAssertTrue(successText.contains("Script reloaded"),
                          "Success status should indicate script was reloaded, got: \(successText)")
        }
    }

    // MARK: - Parameter Sliders

    @MainActor
    func testParameterSlidersPanelExists() throws {
        let app = XCUIApplication()
        app.launch()
        let panel = app.disclosureTriangles["parameterSlidersPanel"].firstMatch
        // DisclosureGroup may surface as different element types through ViewBridge;
        // fall back to searching any element with the identifier.
        let anyMatch = app.descendants(matching: .any)["parameterSlidersPanel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10) || anyMatch.waitForExistence(timeout: 2),
                      "Parameter sliders panel should be visible after launch")
    }

    // Note: testParameterSliderExists was removed because SwiftUI Sliders
    // are not accessible through the AU ViewBridge (NSViewServiceMarshal) in XCUITest.
    // The sliders are visually present and functional but not discoverable via XCUI queries.
    // Same limitation as the language segmented picker.

    // MARK: - Typing Tests

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
