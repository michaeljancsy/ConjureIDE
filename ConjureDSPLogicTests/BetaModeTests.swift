import Foundation
import Testing

@Suite("BetaMode window logic")
struct BetaModeTests {
    private let oneDay: TimeInterval = 24 * 60 * 60
    private let thirtyDays: TimeInterval = 30 * 24 * 60 * 60

    private func buildID(daysAgo: Double, from now: Date) -> Int {
        Int(now.addingTimeInterval(-daysAgo * oneDay).timeIntervalSince1970)
    }

    @Test func notABetaBuildIsAlwaysInactive() {
        let now = Date()
        let bid = buildID(daysAgo: 1, from: now)
        #expect(BetaMode.isActive(isBetaBuild: false, buildID: bid, now: now) == false)
        #expect(BetaMode.secondsRemaining(isBetaBuild: false, buildID: bid, now: now) == 0)
        #expect(BetaMode.expiryDate(isBetaBuild: false, buildID: bid) == nil)
    }

    @Test func freshBetaBuildIsActive() {
        let now = Date()
        let bid = buildID(daysAgo: 0, from: now)
        #expect(BetaMode.isActive(isBetaBuild: true, buildID: bid, now: now) == true)
    }

    @Test func betaBuildStillActiveOnDay29() {
        let now = Date()
        let bid = buildID(daysAgo: 29, from: now)
        #expect(BetaMode.isActive(isBetaBuild: true, buildID: bid, now: now) == true)
    }

    @Test func betaBuildInactiveAtExactlyThirtyDays() {
        let now = Date()
        // Build date exactly 30 days ago → elapsed == durationSeconds, boundary is exclusive.
        let bid = Int(now.addingTimeInterval(-thirtyDays).timeIntervalSince1970)
        #expect(BetaMode.isActive(isBetaBuild: true, buildID: bid, now: now) == false)
    }

    @Test func betaBuildInactiveAfterThirtyDays() {
        let now = Date()
        let bid = buildID(daysAgo: 31, from: now)
        #expect(BetaMode.isActive(isBetaBuild: true, buildID: bid, now: now) == false)
        #expect(BetaMode.secondsRemaining(isBetaBuild: true, buildID: bid, now: now) == 0)
    }

    @Test func zeroBuildIDIsInactive() {
        let now = Date()
        #expect(BetaMode.isActive(isBetaBuild: true, buildID: 0, now: now) == false)
        #expect(BetaMode.secondsRemaining(isBetaBuild: true, buildID: 0, now: now) == 0)
        #expect(BetaMode.expiryDate(isBetaBuild: true, buildID: 0) == nil)
    }

    @Test func secondsRemainingApproximatesFullWindowOnBuildDay() {
        let now = Date()
        let bid = Int(now.timeIntervalSince1970)
        let remaining = BetaMode.secondsRemaining(isBetaBuild: true, buildID: bid, now: now)
        // Should be very close to the full 30 days (allow small slack for clock).
        #expect(remaining > thirtyDays - 2)
        #expect(remaining <= thirtyDays)
    }

    @Test func secondsRemainingIsRoughlyOneDayOnDay29() {
        let now = Date()
        let bid = buildID(daysAgo: 29, from: now)
        let remaining = BetaMode.secondsRemaining(isBetaBuild: true, buildID: bid, now: now)
        // ~1 day left, within a couple of seconds.
        #expect(abs(remaining - oneDay) < 5)
    }

    @Test func expiryDateIsBuildDatePlusThirtyDays() {
        let now = Date()
        let bid = buildID(daysAgo: 2, from: now)
        guard let expiry = BetaMode.expiryDate(isBetaBuild: true, buildID: bid) else {
            Issue.record("Expected an expiry date for a valid Beta buildID")
            return
        }
        let buildDate = Date(timeIntervalSince1970: TimeInterval(bid))
        let delta = expiry.timeIntervalSince(buildDate)
        #expect(abs(delta - thirtyDays) < 0.001)
    }
}
