//
//  LicenseSettingsView.swift
//  BearBoneExtension
//
//  License entry UI for the settings popover.
//  Shows license status and a serial key entry field.
//

import SwiftUI

struct LicenseSettingsView: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var serialInput: String = ""
    @State private var showError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("License")
                .font(.headline)

            if licenseManager.isLicensed {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Licensed")
                        .foregroundColor(.green)
                        .font(.callout)
                }
                .accessibilityIdentifier("licenseStatus")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(demoStatusText)
                        .foregroundColor(.orange)
                        .font(.callout)
                }
                .accessibilityIdentifier("demoStatus")
            }

            Divider()

            Text("Serial Key")
                .font(.subheadline.bold())

            TextField("Paste your serial key\u{2026}", text: $serialInput)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("serialKeyField")

            HStack {
                Spacer()
                Button("Activate") {
                    let success = licenseManager.activate(serial: serialInput)
                    if !success {
                        showError = true
                    } else {
                        serialInput = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(serialInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("activateLicenseButton")
            }

            if showError {
                Text("Invalid serial key")
                    .foregroundColor(.red)
                    .font(.caption)
                    .accessibilityIdentifier("licenseErrorMessage")
            }
        }
        .padding()
        .frame(minWidth: 300)
        .onChange(of: serialInput) { _, _ in
            showError = false
        }
    }

    private var demoStatusText: String {
        let remaining = licenseManager.demoSecondsRemaining
        if remaining <= 0 {
            return "Demo expired"
        }
        return String(format: "Demo \u{2014} %.0fs remaining", remaining)
    }
}
