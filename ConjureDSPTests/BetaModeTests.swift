import Foundation
import Testing

@Suite("BetaMode window logic")
struct BetaModeTests {
    private let oneDay: TimeInterval = 24 * 60 * 60
    private let sevenDays: TimeInterval = 7 * 24 * 60 * 60

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

    @Test func betaBuildStillActiveOnDaySix() {
        let now = Date()
        let bid = buildID(daysAgo: 6, from: now)
        #expect(BetaMode.isActive(isBetaBuild: true, buildID: bid, now: now) == true)
    }

    @Test func betaBuildInactiveAtExactlySevenDays() {
        let now = Date()
        // Build date exactly 7 days ago → elapsed == durationSeconds, boundary is exclusive.
        let bid = Int(now.addingTimeInterval(-sevenDays).timeIntervalSince1970)
        #expect(BetaMode.isActive(isBetaBuild: true, buildID: bid, now: now) == false)
    }

    @Test func betaBuildInactiveAfterSevenDays() {
        let now = Date()
        let bid = buildID(daysAgo: 8, from: now)
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
        // Should be very close to the full 7 days (allow small slack for clock).
        #expect(remaining > sevenDays - 2)
        #expect(remaining <= sevenDays)
    }

    @Test func secondsRemainingIsRoughlyOneDayOnDaySix() {
        let now = Date()
        let bid = buildID(daysAgo: 6, from: now)
        let remaining = BetaMode.secondsRemaining(isBetaBuild: true, buildID: bid, now: now)
        // ~1 day left, within a couple of seconds.
        #expect(abs(remaining - oneDay) < 5)
    }

    @Test func expiryDateIsBuildDatePlusSevenDays() {
        let now = Date()
        let bid = buildID(daysAgo: 2, from: now)
        guard let expiry = BetaMode.expiryDate(isBetaBuild: true, buildID: bid) else {
            Issue.record("Expected an expiry date for a valid Beta buildID")
            return
        }
        let buildDate = Date(timeIntervalSince1970: TimeInterval(bid))
        let delta = expiry.timeIntervalSince(buildDate)
        #expect(abs(delta - sevenDays) < 0.001)
    }
}
