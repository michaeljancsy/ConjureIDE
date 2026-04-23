//
//  LanguageMigrationCoordinatorTests.swift
//  ConjureDSPLogicTests
//
//  Pure-logic tests for the first-launch sheet's shouldShow decision.
//  Injects an isolated UserDefaults suite + a stubbed isInstalled probe
//  so the tests don't touch real preferences or file system state.
//

import Foundation
import Testing

@Suite("LanguageMigrationCoordinator.shouldShow")
struct LanguageMigrationCoordinatorTests {

    /// Produce a fresh, empty UserDefaults suite per test so state never
    /// leaks across cases.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "LanguageMigrationCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Ensure empty even if the suite somehow exists.
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        return defaults
    }

    // MARK: - Show paths

    @Test("Fresh container (no modules, no marker) → show")
    func freshContainerShows() {
        let defaults = makeDefaults()
        let show = LanguageMigrationCoordinator.shouldShow(
            currentBuild: "15",
            defaults: defaults,
            isInstalled: { _ in false }
        )
        #expect(show == true)
    }

    @Test("No modules but different-build marker present → still show")
    func differentBuildWithNoModulesShows() {
        let defaults = makeDefaults()
        defaults.set("14", forKey: LanguageMigrationCoordinator.lastShownBuildKey)
        let show = LanguageMigrationCoordinator.shouldShow(
            currentBuild: "15",
            defaults: defaults,
            isInstalled: { _ in false }
        )
        #expect(show == true)
    }

    // MARK: - Suppress paths

    @Test("Same-build marker present → don't show (even without modules)")
    func sameBuildSuppresses() {
        let defaults = makeDefaults()
        defaults.set("15", forKey: LanguageMigrationCoordinator.lastShownBuildKey)
        let show = LanguageMigrationCoordinator.shouldShow(
            currentBuild: "15",
            defaults: defaults,
            isInstalled: { _ in false }
        )
        #expect(show == false)
    }

    @Test("Python installed + no marker → don't show, stamps marker")
    func pythonInstalledSuppressesAndStamps() {
        let defaults = makeDefaults()
        let show = LanguageMigrationCoordinator.shouldShow(
            currentBuild: "15",
            defaults: defaults,
            isInstalled: { $0 == "python" }
        )
        #expect(show == false)
        #expect(
            defaults.string(forKey: LanguageMigrationCoordinator.lastShownBuildKey) == "15"
        )
    }

    @Test("Rustc installed → don't show, stamps marker")
    func rustcInstalledSuppressesAndStamps() {
        let defaults = makeDefaults()
        let show = LanguageMigrationCoordinator.shouldShow(
            currentBuild: "15",
            defaults: defaults,
            isInstalled: { $0 == "rustc" }
        )
        #expect(show == false)
        #expect(
            defaults.string(forKey: LanguageMigrationCoordinator.lastShownBuildKey) == "15"
        )
    }

    @Test("Both modules installed, older build stamp → don't show, re-stamps to current")
    func bothInstalledOlderStampRestamped() {
        let defaults = makeDefaults()
        defaults.set("14", forKey: LanguageMigrationCoordinator.lastShownBuildKey)
        let show = LanguageMigrationCoordinator.shouldShow(
            currentBuild: "15",
            defaults: defaults,
            isInstalled: { _ in true }
        )
        #expect(show == false)
        #expect(
            defaults.string(forKey: LanguageMigrationCoordinator.lastShownBuildKey) == "15"
        )
    }

    // MARK: - markShown

    @Test("markShown writes current build and is idempotent")
    func markShownWritesCurrentBuild() {
        let defaults = makeDefaults()
        LanguageMigrationCoordinator.markShown(currentBuild: "15", defaults: defaults)
        #expect(
            defaults.string(forKey: LanguageMigrationCoordinator.lastShownBuildKey) == "15"
        )

        LanguageMigrationCoordinator.markShown(currentBuild: "15", defaults: defaults)
        #expect(
            defaults.string(forKey: LanguageMigrationCoordinator.lastShownBuildKey) == "15"
        )
    }

    @Test("After markShown, shouldShow returns false for same build")
    func markShownThenShouldNotShow() {
        let defaults = makeDefaults()
        LanguageMigrationCoordinator.markShown(currentBuild: "15", defaults: defaults)
        let show = LanguageMigrationCoordinator.shouldShow(
            currentBuild: "15",
            defaults: defaults,
            isInstalled: { _ in false }
        )
        #expect(show == false)
    }

    // MARK: - Freshness semantics

    @Test("Wiping modules + clearing marker re-prompts (simulates fresh container)")
    func wipedContainerReprompts() {
        let defaults = makeDefaults()
        // User previously installed + dismissed for this build.
        defaults.set("15", forKey: LanguageMigrationCoordinator.lastShownBuildKey)

        // Container wipe: marker key gone, no modules installed.
        defaults.removeObject(forKey: LanguageMigrationCoordinator.lastShownBuildKey)

        let show = LanguageMigrationCoordinator.shouldShow(
            currentBuild: "15",
            defaults: defaults,
            isInstalled: { _ in false }
        )
        #expect(show == true)
    }
}
