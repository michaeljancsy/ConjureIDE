//
//  SubscriptionTests.swift
//  ConjureDSPTests
//
//  Tests for subscription token verification and kernel integration.
//

import Testing

@Suite("SubscriptionTests")
struct SubscriptionTests {

    // MARK: - FFI Token Verification

    @Test func verifyTokenReturnsStatus() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        // An invalid token should return NoSubscription (4)
        let status = dsp_kernel_verify_token(kernel, "invalid.token")
        #expect(status == 4) // NoSubscription
    }

    @Test func emptyTokenReturnsNoSubscription() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        let status = dsp_kernel_verify_token(kernel, "")
        #expect(status == 4) // NoSubscription
    }

    // MARK: - Subscription Status Transitions

    @Test func activeStatusSetsLicensed() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_set_subscription_status(kernel, 0) // Active
        #expect(dsp_kernel_is_licensed(kernel) == true)
        #expect(dsp_kernel_subscription_status(kernel) == 0)
    }

    @Test func gracePeriodSetsLicensed() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_set_subscription_status(kernel, 1) // GracePeriod
        #expect(dsp_kernel_is_licensed(kernel) == true)
        #expect(dsp_kernel_subscription_status(kernel) == 1)
    }

    @Test func expiredClearsLicensed() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        // First set to active
        dsp_kernel_set_subscription_status(kernel, 0)
        #expect(dsp_kernel_is_licensed(kernel) == true)

        // Then expire
        dsp_kernel_set_subscription_status(kernel, 2) // Expired
        #expect(dsp_kernel_is_licensed(kernel) == false)
        #expect(dsp_kernel_subscription_status(kernel) == 2)
    }

    @Test func cancelledClearsLicensed() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_set_subscription_status(kernel, 3) // Cancelled
        #expect(dsp_kernel_is_licensed(kernel) == false)
        #expect(dsp_kernel_subscription_status(kernel) == 3)
    }

    @Test func noSubscriptionClearsLicensed() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_set_subscription_status(kernel, 4) // NoSubscription
        #expect(dsp_kernel_is_licensed(kernel) == false)
        #expect(dsp_kernel_subscription_status(kernel) == 4)
    }

    // MARK: - Grace Deadline

    @Test func graceDeadlineDefaultsToZero() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        #expect(dsp_kernel_grace_deadline_unix(kernel) == 0)
    }

    // MARK: - Demo Counter

    @Test func demoCounterWorksWhenLicensed() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_set_subscription_status(kernel, 0) // Active
        dsp_kernel_initialize(kernel, 2, 2, 48000)

        // Licensed kernel should report infinite demo time
        let remaining = dsp_kernel_demo_seconds_remaining(kernel, 48000)
        #expect(remaining == Double.infinity)

        dsp_kernel_deinitialize(kernel)
    }

    @Test func demoResetGivesFullTime() {
        let kernel = dsp_kernel_create()!
        defer { dsp_kernel_destroy(kernel) }

        dsp_kernel_set_subscription_status(kernel, 4) // NoSubscription
        dsp_kernel_initialize(kernel, 2, 2, 48000)

        // Verify initial demo time is 60 seconds
        let initial = dsp_kernel_demo_seconds_remaining(kernel, 48000)
        #expect(initial == 60.0)

        // Reset and verify it stays at 60
        dsp_kernel_reset_demo(kernel)
        let afterReset = dsp_kernel_demo_seconds_remaining(kernel, 48000)
        #expect(afterReset == 60.0)

        dsp_kernel_deinitialize(kernel)
    }
}
