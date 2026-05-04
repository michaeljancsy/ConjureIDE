//
//  BetaMode.swift
//  ConjureDSPExtension
//
//  Time-limited "Beta" build mode. When the BETA_BUILD compilation condition
//  is set, the plugin runs without a license for 30 days from the build date,
//  then reverts to the normal Demo behavior. Driven entirely by the BuildID
//  Info.plist value (a Unix timestamp stamped at build time).
//

import Foundation

enum BetaMode {
    /// Thirty days from build date.
    static let durationSeconds: TimeInterval = 30 * 24 * 60 * 60

    /// Whether this binary was compiled with the BETA_BUILD flag set
    /// (regardless of whether the 7-day window has elapsed).
    static var isBetaBuild: Bool {
        #if BETA_BUILD
        return true
        #else
        return false
        #endif
    }

    /// True iff this is a `BETA_BUILD` and the 30-day window has not elapsed.
    static func isActive(buildID: Int, now: Date = Date()) -> Bool {
        isActive(isBetaBuild: isBetaBuild, buildID: buildID, now: now)
    }

    /// Seconds remaining in the Beta window. Returns 0 if Beta is inactive
    /// (either because `BETA_BUILD` is not set or the window has elapsed).
    static func secondsRemaining(buildID: Int, now: Date = Date()) -> TimeInterval {
        secondsRemaining(isBetaBuild: isBetaBuild, buildID: buildID, now: now)
    }

    /// The date at which a Beta build reverts to Demo mode.
    /// Returns `nil` if Beta is not applicable (not a BETA_BUILD or invalid buildID).
    static func expiryDate(buildID: Int) -> Date? {
        expiryDate(isBetaBuild: isBetaBuild, buildID: buildID)
    }

    // MARK: - Pure core (testable without the BETA_BUILD compile flag)

    /// Pure implementation of `isActive` — takes `isBetaBuild` explicitly so
    /// tests can exercise both branches regardless of how the test target was
    /// compiled.
    static func isActive(isBetaBuild: Bool, buildID: Int, now: Date) -> Bool {
        guard isBetaBuild else { return false }
        guard buildID > 0 else { return false }
        let buildDate = Date(timeIntervalSince1970: TimeInterval(buildID))
        return now.timeIntervalSince(buildDate) < durationSeconds
    }

    static func secondsRemaining(isBetaBuild: Bool, buildID: Int, now: Date) -> TimeInterval {
        guard isBetaBuild else { return 0 }
        guard buildID > 0 else { return 0 }
        let buildDate = Date(timeIntervalSince1970: TimeInterval(buildID))
        let elapsed = now.timeIntervalSince(buildDate)
        return max(0, durationSeconds - elapsed)
    }

    static func expiryDate(isBetaBuild: Bool, buildID: Int) -> Date? {
        guard isBetaBuild else { return nil }
        guard buildID > 0 else { return nil }
        let buildDate = Date(timeIntervalSince1970: TimeInterval(buildID))
        return buildDate.addingTimeInterval(durationSeconds)
    }
}
