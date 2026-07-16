//
//  Analytics.swift
//  ConjureDSP
//
//  Thin wrapper around Mixpanel for event tracking.
//  Included in both ConjureDSP (host app) and ConjureDSPExtension targets.
//

import Foundation
import Mixpanel

enum AnalyticsEvent: String {
    case appOpen = "App Open"
    case scriptRun = "Script Run"
    case presetLoad = "Preset Load"
    case presetSave = "Preset Save"
    case export = "Export"
    case aiGenerate = "AI Generate"
}

enum Analytics {
    /// The test target never sends analytics.
    private static let token = ""

    private static var initialized = false

    static func initialize() {
        guard !token.isEmpty, !initialized else { return }
        initialized = true
        Mixpanel.initialize(token: token)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        Mixpanel.mainInstance().registerSuperProperties([
            "app_version": version,
            "platform": "macOS",
        ])
    }

    static func track(_ event: AnalyticsEvent, properties: Properties? = nil) {
        guard !token.isEmpty else { return }
        Mixpanel.mainInstance().track(event: event.rawValue, properties: properties)
    }

    static func flush() {
        guard !token.isEmpty else { return }
        Mixpanel.mainInstance().flush()
    }
}
