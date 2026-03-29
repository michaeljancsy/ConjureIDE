//
//  ConjureDSPApp.swift
//  ConjureDSP
//
//  Created by Michael Jancsy on 2/25/26.
//

import Combine
import Sparkle
import SwiftUI

@main
struct ConjureDSPApp: App {
    private let hostModel = AudioUnitHostModel()
    @StateObject private var exportHandler = PendingExportHandler()
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @StateObject private var checkoutManager = PaddleCheckoutManager()

    init() {
        SentrySetup.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(hostModel: hostModel, exportHandler: exportHandler)
                .onAppear {
                    Analytics.initialize()
                    Analytics.track(.appOpen)
                    Analytics.flush()
                    exportHandler.checkForPendingExports()
                }
                .onOpenURL { url in
                    handleURL(url)
                }
        }
        .defaultSize(width: 700, height: 650)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "conjuredsp" else { return }

        switch url.host {
        case "subscribe":
            checkoutManager.startCheckout()
        default:
            break
        }
    }
}

/// A SwiftUI view that wraps Sparkle's check-for-updates action as a menu item.
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

/// View model that observes the updater's `canCheckForUpdates` property.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private var cancellable: Any?

    init(updater: SPUUpdater) {
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
    }
}
