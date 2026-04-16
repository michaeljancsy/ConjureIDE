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
    case subscriptionActivate = "Subscription Activate"
    case terminalToggle = "Terminal Toggle"
    case spectrogramToggle = "Spectrogram Toggle"
    case githubRepoConnect = "GitHub Repo Connect"
    case namToneDownload = "NAM Tone Download"
    case namToneInsert = "NAM Tone Insert"
    case packageInstall = "Package Install"
    case crateInstall = "Crate Install"
}

enum Analytics {
    #if DEBUG
    private static let token = ""
    #else
    private static let token = "54ee78fc2e8026396e096f94b87e51f2"
    #endif

    private static var initialized = false

    /// Broad classification of the running binary, attached to every Mixpanel
    /// event as a `build_mode` super property so dev / beta / production traffic
    /// can be distinguished. `debug` wins over everything (only relevant if the
    /// DEBUG token is ever populated); `beta` means BETA_BUILD is active and
    /// within its 7-day window; `licensed` and `demo` reflect subscription state
    /// for a regular Release build.
    enum BuildMode: String {
        case debug
        case beta
        case licensed
        case demo
    }

    /// Compute the current build mode from compile flags + runtime license state.
    static func currentMode(licensed: Bool, betaActive: Bool) -> BuildMode {
        #if DEBUG
        return .debug
        #else
        if betaActive { return .beta }
        return licensed ? .licensed : .demo
        #endif
    }

    static func initialize() {
        guard !token.isEmpty, !initialized else { return }
        initialized = true
        Mixpanel.initialize(token: token)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        // Seed `build_mode` with compile-flag-only state. SubscriptionManager
        // calls `updateMode` once it has verified the license, which overwrites
        // this with the real licensed/demo/beta value.
        Mixpanel.mainInstance().registerSuperProperties([
            "app_version": version,
            "platform": "macOS",
            "build_mode": currentMode(licensed: false, betaActive: false).rawValue,
        ])
    }

    /// Refresh the `build_mode` super property. Safe to call before `initialize()`
    /// (no-op in that case) and before Mixpanel has a token (DEBUG builds).
    static func updateMode(licensed: Bool, betaActive: Bool) {
        guard !token.isEmpty, initialized else { return }
        Mixpanel.mainInstance().registerSuperProperties([
            "build_mode": currentMode(licensed: licensed, betaActive: betaActive).rawValue,
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

    static func identify(licenseHash: String) {
        guard !token.isEmpty else { return }
        Mixpanel.mainInstance().identify(distinctId: licenseHash)
        Mixpanel.mainInstance().people.set(properties: ["licensed": true])
    }
}
