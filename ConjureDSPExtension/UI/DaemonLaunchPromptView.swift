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
    }

    private var daemonIcon: Image {
        let bundle = Bundle(for: AudioUnitViewController.self)
        if let url = bundle.url(forResource: "daemon-icon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            return Image(nsImage: nsImage)
        }
        // Fallback to SF Symbol if resource missing
        return Image(systemName: "terminal")
    }
}
