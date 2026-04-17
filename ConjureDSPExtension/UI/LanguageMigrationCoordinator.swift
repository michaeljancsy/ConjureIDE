//
//  LanguageMigrationCoordinator.swift
//  ConjureDSPExtension
//
//  Decides whether the first-launch language sheet should appear. Split into
//  its own file so the pure-logic policy can be unit-tested from
//  ConjureDSPLogicTests without pulling in the SwiftUI sheet view.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "LanguageMigration")

enum LanguageMigrationCoordinator {
    /// UserDefaults key holding the build number of the last build that
    /// showed the sheet. Stored in the App Group preferences suite so it
    /// lives inside `~/Library/Group Containers/group.com.MichaelJancsy.ConjureDSP/`
    /// — nuking the App Group container resets the marker, so a truly
    /// fresh install re-prompts even if the user had previously dismissed
    /// the sheet on the same bundle ID.
    static let lastShownBuildKey = "ConjureDSPLanguageMigrationShownForBuild"

    /// App Group-scoped UserDefaults. Falls back to `.standard` if the
    /// suite isn't available (shouldn't happen in shipping builds, but
    /// keeps the sheet usable in unit tests / dev harnesses).
    static var defaults: UserDefaults {
        UserDefaults(suiteName: AppGroupContainer.id) ?? .standard
    }

    /// Testable core. Re-prompt every time the App Group container is
    /// fresh (no modules + no marker). A user who wipes `LanguageModules/`
    /// (or reinstalls onto a clean container) gets the welcome sheet
    /// again, not silence.
    static func shouldShow(
        currentBuild: String,
        defaults: UserDefaults,
        isInstalled: (String) -> Bool
    ) -> Bool {
        let haveAnyModule = isInstalled("python") || isInstalled("rustc")
        let lastShown = defaults.string(forKey: lastShownBuildKey) ?? ""

        // Fresh container — re-prompt regardless of past builds.
        if !haveAnyModule && lastShown.isEmpty {
            return true
        }

        // Already marked for this build → don't pester.
        if lastShown == currentBuild {
            return false
        }

        // New build number + no modules → show.
        if !haveAnyModule {
            return true
        }

        // Modules already installed, the user knows the panel. Stamp so
        // we don't check on every subsequent launch.
        defaults.set(currentBuild, forKey: lastShownBuildKey)
        return false
    }

    static func markShown(currentBuild: String) {
        markShown(currentBuild: currentBuild, defaults: defaults)
    }

    static func markShown(currentBuild: String, defaults: UserDefaults) {
        defaults.set(currentBuild, forKey: lastShownBuildKey)
        log.info("Marked language sheet shown for build \(currentBuild, privacy: .public)")
    }
}
