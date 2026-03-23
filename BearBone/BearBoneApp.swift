//
//  BearBoneApp.swift
//  BearBone
//
//  Created by Michael Jancsy on 2/25/26.
//

import SwiftUI

@main
struct BearBoneApp: App {
    private let hostModel = AudioUnitHostModel()
    @StateObject private var exportHandler = PendingExportHandler()

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
                    DispatchQueue.global(qos: .utility).async {
                        SharedPythonRuntimeInstaller.installIfNeeded()
                    }
                }
        }
        .defaultSize(width: 700, height: 650)
    }
}
