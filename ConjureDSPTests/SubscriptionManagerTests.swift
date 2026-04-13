//
//  SubscriptionManagerTests.swift
//  ConjureDSPTests
//
//  Tests that require SubscriptionManager (linked to host app via TEST_HOST).
//

import Testing

@Suite("SubscriptionManagerTests")
struct SubscriptionManagerTests {

    @MainActor
    @Test func subscriptionManagerInitializesAsDemoMode() {
        let manager = SubscriptionManager()
        #expect(manager.status == .noSubscription)
        #expect(manager.isLicensed == false)
        #expect(manager.demoSecondsRemaining == 60.0)
    }
}
