//
//  SubscriptionSettingsView.swift
//  ConjureDSPExtension
//
//  Shows subscription status and management controls.
//

import SwiftUI

struct SubscriptionSettingsView: View {
    static let subscribeURL = URL(string: "https://conjuredsp.com/subscribe")!

    @ObservedObject var subscriptionManager: SubscriptionManager

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
    private var actionSection: some View {
        switch subscriptionManager.status {
        case .active:
            Button("Manage Subscription") {
                if let url = URL(string: "https://conjuredsp.com/account") {
                    NSWorkspace.shared.open(url)
                }
            }
            .accessibilityIdentifier("manageSubscriptionButton")

        case .gracePeriod:
            Button("Manage Subscription") {
                if let url = URL(string: "https://conjuredsp.com/account") {
                    NSWorkspace.shared.open(url)
                }
            }

        case .expired, .cancelled:
            Button("Subscribe") {
                if let url = URL(string: "https://conjuredsp.com/subscribe") {
                    NSWorkspace.shared.open(url)
                }
            }
            .accessibilityIdentifier("subscribeButton")

            Button("Restart Demo") {
                subscriptionManager.restartDemo()
            }
            .disabled(subscriptionManager.demoSecondsRemaining > 0)
            .accessibilityIdentifier("restartDemoButton")

        case .noSubscription:
            Button("Subscribe") {
                if let url = URL(string: "https://conjuredsp.com/subscribe") {
                    NSWorkspace.shared.open(url)
                }
            }
            .accessibilityIdentifier("subscribeButton")

            Button("Restart Demo") {
                subscriptionManager.restartDemo()
            }
            .disabled(subscriptionManager.demoSecondsRemaining > 0)
            .accessibilityIdentifier("restartDemoButton")
        }
    }
}
