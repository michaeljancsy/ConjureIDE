//
//  PluginCrashRecoveryUITests.swift
//  ConjureDSPUITests
//
//  The plugin runs in its own process, separate from the host app. When that
//  process dies, the host window has to say so and offer a reload. Without
//  that, the window went blank with Play still live, and pressing Play
//  crashed the app (Sentry CONJUREDSP-6H, release 3.1.0).
//

import XCTest

final class PluginCrashRecoveryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStoppedPluginShowsReloadAndRecovers() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        // The Run button lives in the plugin's own UI, so seeing it means the
        // plugin process is up and its view is hosted in the window.
        XCTAssertTrue(app.buttons["runButton"].waitForExistence(timeout: 30),
                      "Plugin UI should load")
        let playButton = app.buttons["Play"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))

        try killPluginProcess()

        let reloadButton = app.buttons["reloadPluginButton"]
        XCTAssertTrue(reloadButton.waitForExistence(timeout: 15),
                      "Window should offer Reload Plugin once the plugin's process stops")
        XCTAssertFalse(playButton.isEnabled, "Play must be off while the plugin is gone")
        XCTAssertEqual(app.state, .runningForeground)

        reloadButton.click()

        XCTAssertTrue(app.buttons["runButton"].waitForExistence(timeout: 30),
                      "Plugin UI should come back after Reload Plugin")
        XCTAssertTrue(playButton.waitForExistence(timeout: 10))
        XCTAssertTrue(playButton.isEnabled)

        playButton.click()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10),
                      "Playback should start with the reloaded plugin")
        app.buttons["Stop"].click()
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Force-quits every running Debug-identity plugin process. Matching by
    /// path doesn't work: PluginKit picks one registered copy of the Debug
    /// extension (often from another worktree's build folder) no matter which
    /// host asked, and the test runner's sandbox blocks pkill's process list.
    /// The Release plugin has a different bundle ID and is never touched.
    private func killPluginProcess() throws {
        let plugins = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.MichaelJancsy.ConjureDSP.debug.ConjureDSPExtension"
        )
        XCTAssertFalse(plugins.isEmpty, "No running plugin process to stop")
        for plugin in plugins {
            XCTAssertTrue(plugin.forceTerminate(), "Could not stop plugin process \(plugin.processIdentifier)")
        }
    }
}
