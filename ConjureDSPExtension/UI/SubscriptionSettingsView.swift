//
//  SubscriptionSettingsView.swift
//  ConjureDSPExtension
//
//  Shows subscription status and management controls.
//

import SwiftUI

struct SubscriptionSettingsView: View {
    static let subscribeURL = URL(string: "https://www.conjuredsp.com/subscribe")!

    @ObservedObject var subscriptionManager: SubscriptionManager
    @State private var activationKey = ""
    @State private var isActivating = false
    @State private var activationError: String?
    @State private var showDeactivateConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscription")
                .font(.headline)

            statusSection

            actionSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch subscriptionManager.status {
        case .active:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Active")
                    .foregroundColor(.green)
                    .fontWeight(.medium)
            }
            if let email = subscriptionManager.email {
                Text(email)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        case .gracePeriod:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Grace Period")
                    .foregroundColor(.orange)
                    .fontWeight(.medium)
            }
            Text("Connect to the internet to verify your subscription.")
                .font(.caption)
                .foregroundColor(.secondary)

        case .expired:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text("Expired")
                    .foregroundColor(.red)
                    .fontWeight(.medium)
            }
            Text("Your subscription has expired.")
                .font(.caption)
                .foregroundColor(.secondary)

        case .cancelled:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text("Cancelled")
                    .foregroundColor(.red)
                    .fontWeight(.medium)
            }
            Text("Your subscription was cancelled.")
                .font(.caption)
                .foregroundColor(.secondary)

        case .noSubscription:
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .foregroundColor(.secondary)
                Text("Demo Mode")
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)
            }
            let remaining = Int(subscriptionManager.demoSecondsRemaining)
            if remaining > 0 {
                Text("\(remaining)s of demo remaining")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Demo time expired")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var activationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activation Key")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField("txn_...", text: $activationKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("activationKeyField")
                Button(isActivating ? "Activating..." : "Activate") {
                    Task {
                        isActivating = true
                        activationError = nil
                        do {
                            try await subscriptionManager.activate(transactionID: activationKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            activationKey = ""
                        } catch {
                            activationError = error.localizedDescription
                        }
                        isActivating = false
                    }
                }
                .disabled(activationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)
                .accessibilityIdentifier("activateButton")
            }
            if let error = activationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        switch subscriptionManager.status {
        case .active:
            Button("Manage Subscription") {
                if let url = URL(string: "https://www.conjuredsp.com/account") {
                    NSWorkspace.shared.open(url)
                }
            }
            .accessibilityIdentifier("manageSubscriptionButton")

            deactivateButton

        case .gracePeriod:
            Button("Manage Subscription") {
                if let url = URL(string: "https://www.conjuredsp.com/account") {
                    NSWorkspace.shared.open(url)
                }
            }

            deactivateButton

        case .expired, .cancelled, .noSubscription:
            Button("Subscribe") {
                if let url = URL(string: "https://www.conjuredsp.com/subscribe") {
                    NSWorkspace.shared.open(url)
                }
            }
            .accessibilityIdentifier("subscribeButton")

            activationSection

            Button("Restart Demo") {
                subscriptionManager.restartDemo()
            }
            .disabled(subscriptionManager.demoSecondsRemaining > 0)
            .accessibilityIdentifier("restartDemoButton")
        }
    }

    @ViewBuilder
    private var deactivateButton: some View {
        Button("Deactivate License") {
            showDeactivateConfirmation = true
        }
        .accessibilityIdentifier("deactivateLicenseButton")
        .confirmationDialog(
            "Deactivate ConjureDSP's license on this machine?",
            isPresented: $showDeactivateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Deactivate License", role: .destructive) {
                subscriptionManager.deactivateLicense()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deactivating the license on this machine will allow you to activate ConjureDSP on a different machine. This machine will revert to \"Demo\" mode unless activated again with an activation key. Are you sure you want to deactivate ConjureDSP's license on this machine?")
        }
    }
}
