//
//  PopoverTextFieldCrashUITests.swift
//  ConjureDSPUITests
//
//  Guards Sentry CONJUREDSP-6E: the plugin process aborted in ViewBridge
//  ("invalid parameter not satisfying: options.orderingMode ==
//  _windowOrderingMode" in -[NSViewServiceMarshal orderWindow:options:])
//  when a popover closed while its text field was editing and the text
//  cursor's caps lock / keyboard layout indicator was on screen. Ending the
//  edit removed the indicator's window in the middle of the popover's own
//  window reorder.
//
//  Each test raises the caps lock indicator in a popover's text field,
//  closes the popover from one of its own buttons, and checks the plugin's
//  process survived (the host shows Reload Plugin when it stops).
//

import IOKit
import IOKit.hid
import XCTest

final class PopoverTextFieldCrashUITests: XCTestCase {

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
        // Never leave the user's caps lock on.
        setCapsLock(false)
        guard let app = Self.sharedApp else { return }
        let reload = app.buttons["reloadPluginButton"]
        if reload.exists {
            app.activate()
            reload.click()
            _ = app.buttons["runButton"].waitForExistence(timeout: 30)
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    @MainActor
    func testNewPresetCancelWithCapsLockIndicator() throws {
        try closeWithIndicatorShowing(openButton: "newScriptButton", field: "newPresetNameField") { app in
            app.buttons["Cancel"].firstMatch.click()
        }
    }

    @MainActor
    func testSaveAsCancelWithCapsLockIndicator() throws {
        try closeWithIndicatorShowing(openButton: "saveAsButton", field: "presetNameField") { app in
            app.buttons["Cancel"].firstMatch.click()
        }
    }

    // MARK: - Helpers

    @MainActor
    private func closeWithIndicatorShowing(openButton: String, field fieldID: String,
                                           close: (XCUIApplication) -> Void) throws {
        let app = Self.sharedApp!
        XCTAssertTrue(app.buttons["runButton"].waitForExistence(timeout: 30), "Plugin UI should load")

        try openToolbarPopover(app: app, buttonId: openButton)
        let field = anyElement(in: app, id: fieldID)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(fieldID) should appear")
        field.click()
        field.typeText("x")

        // XCUITest's caps lock key event doesn't change the lock state, and
        // setting the state on the HID system doesn't raise the indicator;
        // together they do.
        setCapsLock(true)
        app.typeKey(.capsLock, modifierFlags: [])
        XCTAssertTrue(waitForIndicator(), "The caps lock indicator didn't appear, so the test can't exercise the crash")

        close(app)

        XCTAssertFalse(app.buttons["reloadPluginButton"].waitForExistence(timeout: 5),
                       "Plugin process stopped when the popover closed (CONJUREDSP-6E)")
    }

    /// The indicator is a small (about 84x77) window owned by the host app:
    /// ViewBridge draws the plugin's windows through host-side windows.
    private func waitForIndicator() -> Bool {
        for _ in 0..<30 {
            let hosts = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.MichaelJancsy.ConjureDSP.debug")
                .map(\.processIdentifier))
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let showing = windows.contains { window in
                guard hosts.contains((window[kCGWindowOwnerPID as String] as? pid_t) ?? -1),
                      let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
                return (bounds["Width"] ?? .infinity) < 150 && (bounds["Height"] ?? .infinity) < 150
            }
            if showing { return true }
            usleep(100_000)
        }
        return false
    }

    private func withHIDSystem<T>(_ body: (io_connect_t) -> T) -> T? {
        var connect: io_connect_t = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            return nil
        }
        defer { IOServiceClose(connect) }
        return body(connect)
    }

    private func capsLockIsOn() -> Bool {
        withHIDSystem { connect in
            var state = false
            IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
            return state
        } ?? false
    }

    private func setCapsLock(_ on: Bool) {
        _ = withHIDSystem { IOHIDSetModifierLockState($0, Int32(kIOHIDCapsLockState), on) }
        for _ in 0..<20 where capsLockIsOn() != on { usleep(100_000) }
    }
}
