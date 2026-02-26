//
//  TestPluginApp.swift
//  TestPlugin
//
//  Created by Michael Jancsy on 2/25/26.
//

import SwiftUI

@main
struct TestPluginApp: App {
    private let hostModel = AudioUnitHostModel()

    var body: some Scene {
        WindowGroup {
            ContentView(hostModel: hostModel)
        }
    }
}
