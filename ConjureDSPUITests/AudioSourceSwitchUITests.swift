//
//  AudioSourceSwitchUITests.swift
//  ConjureDSPUITests
//
//  Picking a different audio source while playing reloads the file, which
//  stops the engine. The host model then starts it again; if that restart
//  fails, the window shows "Playback couldn't start." instead of crashing.
//  This checks the restart succeeds and playback carries on.
//

import XCTest

final class AudioSourceSwitchUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSwitchingSourceWhilePlayingKeepsPlaying() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        // The Run button lives in the plugin's own UI, so seeing it means the
        // plugin process is up and its view is hosted in the window.
        XCTAssertTrue(app.buttons["runButton"].waitForExistence(timeout: 30),
                      "Plugin UI should load")
        let sourceMenu = anyElement(in: app, id: "audioSourceMenu")
        XCTAssertTrue(sourceMenu.waitForExistence(timeout: 10))

        let playButton = app.buttons["Play"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        playButton.click()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10),
                      "Playback should start")

        // The window opens on whichever source was picked last, so switch to
        // a built-in that isn't the current one, then back if we can.
        let original = sourceMenu.title
        let target = original == "White Noise" ? "A440 Sine" : "White Noise"
        try switchSource(app, menu: sourceMenu, to: target)
        if ["A440 Sine", "White Noise", "A55 Sawtooth Series", "A Octave Stack", "Synth"].contains(original) {
            try switchSource(app, menu: sourceMenu, to: original)
        }

        app.buttons["Stop"].click()
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
    }

    private func switchSource(_ app: XCUIApplication, menu: XCUIElement, to name: String) throws {
        menu.click()
        let item = app.menuItems[name]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Audio source menu should list \(name)")
        item.click()

        let switched = expectation(for: NSPredicate(format: "title == %@", name), evaluatedWith: menu)
        wait(for: [switched], timeout: 5)

        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5),
                      "Playback should still be running after switching to \(name)")
        XCTAssertFalse(app.buttons["Play"].exists,
                       "Play showing means the restart after switching to \(name) failed")
        XCTAssertFalse(app.staticTexts["Playback couldn't start."].waitForExistence(timeout: 2),
                       "No start error should appear after switching to \(name)")
    }
}
