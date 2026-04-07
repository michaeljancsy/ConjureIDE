//
//  DaemonLaunchPromptView.swift
//  ConjureDSPExtension
//
//  Shown in the terminal panel when the ConjureDSP Terminal daemon
//  is not running. Displays the daemon icon and instructions.
//

import SwiftUI

struct DaemonLaunchPromptView: View {
    var colorScheme: ColorScheme

    var body: some View {
        VStack(spacing: 16) {
            daemonIcon
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .cornerRadius(12)

            Text("Launch ConjureDSP Terminal")
                .font(.headline)
                .foregroundColor(colorScheme == .dark ? .white : .primary)

            Text("Open the ConjureDSP Terminal app to connect Claude Code to your plugin.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorScheme == .dark ? Color(white: 0.12) : Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("daemonLaunchPrompt")
    }
}

/// Sheet shown when the user tries to export but the daemon isn't running.
struct DaemonRequiredAlertView: View {
    var colorScheme: ColorScheme
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            daemonIcon
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .cornerRadius(12)

            Text("Launch ConjureDSP Terminal")
                .font(.headline)
                .foregroundColor(colorScheme == .dark ? .white : .primary)

            Text("Open the ConjureDSP Terminal app to enable exporting.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("OK") { onDismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 300)
    }
}

private var daemonIcon: Image {
    let bundle = Bundle(for: AudioUnitViewController.self)
    if let url = bundle.url(forResource: "daemon-icon", withExtension: "png"),
       let nsImage = NSImage(contentsOf: url) {
        return Image(nsImage: nsImage)
    }
    return Image(systemName: "terminal")
}
