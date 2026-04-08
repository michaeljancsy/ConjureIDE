//
//  DaemonLaunchPromptView.swift
//  ConjureDSPExtension
//
//  Shown in the terminal panel when the ConjureDSP Terminal daemon
//  is not running. Displays the daemon icon and instructions.
//

import AppKit
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

            Text("ConjureDSP Terminal")
                .font(.headline)
                .foregroundColor(colorScheme == .dark ? .white : .primary)

            Text("The terminal is starting. If it doesn't connect, click the button below.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("Launch Terminal") {
                launchTerminalApp()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
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

            Text("ConjureDSP Terminal Required")
                .font(.headline)
                .foregroundColor(colorScheme == .dark ? .white : .primary)

            Text("The terminal must be running to export presets.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button("Launch Terminal") {
                    launchTerminalApp()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Cancel") { onDismiss() }
                    .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 300)
    }
}

/// Launch the embedded ConjureDSPTerminal.app by path.
/// Uses `openApplication(at:)` to avoid Apple Events TCC prompts.
private func launchTerminalApp() {
    let extensionBundle = Bundle(for: AudioUnitViewController.self)
    let terminalURL = extensionBundle.bundleURL
        .deletingLastPathComponent()   // Contents/PlugIns/
        .deletingLastPathComponent()   // Contents/
        .appendingPathComponent("Library/ConjureDSPTerminal.app")

    guard FileManager.default.fileExists(atPath: terminalURL.path) else { return }
    let config = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.openApplication(at: terminalURL, configuration: config, completionHandler: nil)
}

private var daemonIcon: Image {
    let bundle = Bundle(for: AudioUnitViewController.self)
    if let url = bundle.url(forResource: "daemon-icon", withExtension: "png"),
       let nsImage = NSImage(contentsOf: url) {
        return Image(nsImage: nsImage)
    }
    return Image(systemName: "terminal")
}
