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

    var body: some Scene {
        WindowGroup {
            ContentView(hostModel: hostModel, exportHandler: exportHandler)
                .onAppear {
                    exportHandler.checkForPendingExports()
                }
        }
        .defaultSize(width: 700, height: 650)
    }
}
