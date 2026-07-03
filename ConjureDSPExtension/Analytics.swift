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
    case terminalToggle = "Terminal Toggle"
    case spectrogramToggle = "Spectrogram Toggle"
    case githubRepoConnect = "GitHub Repo Connect"
    case namToneDownload = "NAM Tone Download"
    case namToneInsert = "NAM Tone Insert"
    case packageInstall = "Package Install"
    case crateInstall = "Crate Install"
    case mcpToolCall = "MCP Tool Call"
    case terminalFirstInput = "Terminal First Input"
}

enum Analytics {
    #if DEBUG
    private static let token = ""
    #else
    private static let token = "54ee78fc2e8026396e096f94b87e51f2"
    #endif

    private static var initialized = false

    /// Broad classification of the running binary, attached to every Mixpanel
    /// event as a `build_mode` super property so dev traffic can be
    /// distinguished from production. `debug` wins when the DEBUG token is ever
    /// populated; otherwise `release`.
    enum BuildMode: String {
        case debug
        case release
    }

    /// The current build mode, derived purely from compile flags.
    static var currentMode: BuildMode {
        #if DEBUG
        return .debug
        #else
        return .release
        #endif
    }

    static func initialize() {
        guard !token.isEmpty, !initialized else { return }
        initialized = true
        Mixpanel.initialize(token: token)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        Mixpanel.mainInstance().registerSuperProperties([
            "app_version": version,
            "platform": "macOS",
            "build_mode": currentMode.rawValue,
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
