//
//  SubscriptionManager.swift
//  ConjureDSPExtension
//
//  Manages subscription verification and periodic refresh.
//  Tokens are stored in the App Group container shared with the host app.
//  The kernel's licensed flag is set based on subscription status.
//

import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "SubscriptionManager")

/// Subscription status enum matching Rust SubscriptionStatus (license.rs).
enum SubscriptionStatus: UInt8, CaseIterable {
    case active = 0
    case gracePeriod = 1
    case expired = 2
    case cancelled = 3
    case noSubscription = 4

    var isLicensed: Bool {
        self == .active || self == .gracePeriod
    }

    var displayName: String {
        switch self {
        case .active: return "Active"
        case .gracePeriod: return "Grace Period"
        case .expired: return "Expired"
        case .cancelled: return "Cancelled"
        case .noSubscription: return "Demo"
        }
    }
}

@MainActor
class SubscriptionManager: ObservableObject {
    @Published private(set) var status: SubscriptionStatus = .noSubscription
    @Published private(set) var demoSecondsRemaining: Double = 60.0
    @Published private(set) var email: String?

    /// Whether the user currently has licensed access (active or grace period).
    var isLicensed: Bool { status.isLicensed }

    /// App Group container identifier shared between host app and AU extension.
    static let appGroupIdentifier = AppGroupContainer.id

    /// Pre-resolved App Group container URL (resolved once at startup).
    private let appGroupContainerURL: URL

    /// Token filename within the App Group container.
    private static let tokenFilename = "subscription_token"

    // MARK: - Kernel Closures

    /// Verify a token via the Rust kernel FFI. Returns SubscriptionStatus raw value.
    var verifyTokenWithKernel: ((String) -> UInt8)?

    /// Set the subscription status in the kernel directly.
    var setSubscriptionStatusInKernel: ((UInt8) -> Void)?

    /// Get remaining demo seconds from the kernel.
    var getDemoSecondsRemaining: (() -> Double)?

    /// Reset the demo counter in the kernel.
    var resetDemoInKernel: (() -> Void)?

    /// Get grace deadline (Unix seconds) from the kernel.
    var getGraceDeadlineUnix: (() -> Int64)?

    // MARK: - Timers

    /// Demo countdown timer (1s interval).
    private var demoTimer: Timer?

    /// Periodic server refresh timer.
    private var refreshTimer: Timer?

    /// Cached token for server refresh.
    private var cachedToken: String?

    // MARK: - Refresh Intervals

    /// How often to refresh when subscription is active (15 minutes).
    private static let activeRefreshInterval: TimeInterval = 15 * 60

    /// How often to refresh during grace period (1 hour).
    private static let graceRefreshInterval: TimeInterval = 1 * 60 * 60

    // MARK: - Init

    init(appGroupContainerURL: URL = AppGroupContainer.url) {
        self.appGroupContainerURL = appGroupContainerURL
    }

    /// Load cached token from App Group and verify with kernel.
    func loadAndVerify() {
        #if FORCE_LICENSE
        // Skip server verification — force licensed status for development
        status = .active
        setSubscriptionStatusInKernel?(SubscriptionStatus.active.rawValue)
        return
        #endif
        guard let token = loadToken() else {
            log.info("No cached subscription token found")
            status = .noSubscription
            setSubscriptionStatusInKernel?(SubscriptionStatus.noSubscription.rawValue)
            startDemoTimer()
            return
        }

        cachedToken = token
        verifyAndUpdateStatus(token: token)

        // If licensed, schedule periodic refresh
        if status.isLicensed {
            scheduleRefresh()
        }

        // Extract email from token for display
        email = parseEmailFromToken(token)

        // Set Sentry user context for all future events
        SentryHelper.configureUser(subscriptionStatus: status.displayName, email: email)
    }

    // MARK: - Token Verification

    private func verifyAndUpdateStatus(token: String) {
        guard let rawStatus = verifyTokenWithKernel?(token) else {
            log.warning("No kernel verify closure set")
            SentryHelper.capture("Kernel verify closure not set", level: .warning, category: "subscription")
            status = .noSubscription
            startDemoTimer()
            return
        }

        let newStatus = SubscriptionStatus(rawValue: rawStatus) ?? .noSubscription
        let previousStatus = status
        status = newStatus

        if newStatus.isLicensed {
            log.info("Subscription status: \(newStatus.displayName, privacy: .public)")
            stopDemoTimer()
            if newStatus == .gracePeriod && previousStatus != .gracePeriod {
                Analytics.track(.subscriptionActivate, properties: ["status": "grace_period"])
            }
        } else {
            log.info("Not licensed, status: \(newStatus.displayName, privacy: .public)")
            startDemoTimer()
        }
    }

    // MARK: - Activation

    /// Activate a subscription using a transaction ID from Paddle checkout.
    func activate(transactionID: String) async throws {
        let machineID = SubscriptionAPI.machineID()
        let token = try await SubscriptionAPI.activate(transactionID: transactionID, machineID: machineID)

        try saveToken(token)
        cachedToken = token
        verifyAndUpdateStatus(token: token)
        email = parseEmailFromToken(token)

        log.info("Subscription activated, status: \(self.status.displayName, privacy: .public)")

        if status.isLicensed {
            scheduleRefresh()
        }
    }

    // MARK: - Deactivation

    /// Clear the locally cached subscription token and return to demo mode.
    /// Does not contact the server; the server-side activation record remains
    /// until the subscription expires naturally.
    func deactivateLicense() {
        // Delete the token file from the App Group container.
        let tokenURL = appGroupContainerURL.appendingPathComponent(Self.tokenFilename)
        try? FileManager.default.removeItem(at: tokenURL)

        // Stop the periodic server refresh.
        refreshTimer?.invalidate()
        refreshTimer = nil

        // Clear in-memory state.
        cachedToken = nil
        email = nil

        // Reset kernel + published status to no-subscription and start demo countdown.
        status = .noSubscription
        setSubscriptionStatusInKernel?(SubscriptionStatus.noSubscription.rawValue)
        resetDemoInKernel?()
        updateDemoTime()
        startDemoTimer()

        SentryHelper.configureUser(subscriptionStatus: status.displayName, email: nil)
        log.info("License deactivated on this machine; reverted to demo mode")
    }

    // MARK: - Server Refresh

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        let interval = status == .gracePeriod
            ? Self.graceRefreshInterval
            : Self.activeRefreshInterval

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshFromServer()
            }
        }
    }

    private func refreshFromServer() async {
        guard let token = cachedToken else { return }

        do {
            let machineID = SubscriptionAPI.machineID()
            let freshToken = try await SubscriptionAPI.verify(token: token, machineID: machineID)

            // Save and verify fresh token
            try saveToken(freshToken)
            cachedToken = freshToken
            verifyAndUpdateStatus(token: freshToken)
            email = parseEmailFromToken(freshToken)

            log.info("Token refreshed from server, status: \(self.status.displayName, privacy: .public)")

            // Reschedule based on new status
            if status.isLicensed {
                scheduleRefresh()
            } else {
                refreshTimer?.invalidate()
                refreshTimer = nil
            }
        } catch {
            log.warning("Server refresh failed: \(error.localizedDescription, privacy: .public)")
            SentryHelper.captureError(error, category: "subscription", extra: ["status": status.displayName])
            // Keep using cached token — grace period handles offline
        }
    }

    // MARK: - Demo

    func restartDemo() {
        resetDemoInKernel?()
        updateDemoTime()
    }

    private func startDemoTimer() {
        guard demoTimer == nil else { return }
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateDemoTime()
        }
    }

    private func stopDemoTimer() {
        demoTimer?.invalidate()
        demoTimer = nil
    }

    private func updateDemoTime() {
        demoSecondsRemaining = getDemoSecondsRemaining?() ?? 0
    }

    // MARK: - Token Persistence (App Group)

    private func loadToken() -> String? {
        let tokenURL = appGroupContainerURL.appendingPathComponent(Self.tokenFilename)
        guard let data = FileManager.default.contents(atPath: tokenURL.path),
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveToken(_ token: String) throws {
        let tokenURL = appGroupContainerURL.appendingPathComponent(Self.tokenFilename)
        try token.write(to: tokenURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Token Parsing

    /// Extract email from a token's base64-encoded JSON payload.
    private func parseEmailFromToken(_ token: String) -> String? {
        let parts = token.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let data = Data(base64Encoded: String(parts[0])),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else {
            return nil
        }
        return email
    }
}
