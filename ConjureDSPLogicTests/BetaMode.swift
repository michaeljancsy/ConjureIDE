//
//  BetaMode.swift
//  ConjureDSPTests
//
//  Test-target copy of BetaMode. Kept in sync with
//  ConjureDSPExtension/Model/BetaMode.swift — the test target cannot import
//  the AU extension module, so we mirror the file here. Only the pure-core
//  overloads are exercised in tests; the compile-time BETA_BUILD variants
//  delegate to them.
//

import Foundation

enum BetaMode {
    static let durationSeconds: TimeInterval = 30 * 24 * 60 * 60

    static var isBetaBuild: Bool {
        #if BETA_BUILD
        return true
        #else
        return false
        #endif
    }

    static func isActive(buildID: Int, now: Date = Date()) -> Bool {
        isActive(isBetaBuild: isBetaBuild, buildID: buildID, now: now)
    }

    static func secondsRemaining(buildID: Int, now: Date = Date()) -> TimeInterval {
        secondsRemaining(isBetaBuild: isBetaBuild, buildID: buildID, now: now)
    }

    static func expiryDate(buildID: Int) -> Date? {
        expiryDate(isBetaBuild: isBetaBuild, buildID: buildID)
    }

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
