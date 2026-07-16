import Foundation
import Sentry

/// Resolves the bundle this file was compiled into — unlike Bundle.main,
/// which is the host DAW's bundle when the AU is loaded in-process.
private final class SentryBundleToken {}

/// Populated from the ConjureSentryDSN Info.plist key, which mirrors the
/// CONJURE_SENTRY_DSN build setting (Config/Local.xcconfig). Empty or missing
/// means crash reporting stays disabled.
let sentryDSN = Bundle(for: SentryBundleToken.self)
    .object(forInfoDictionaryKey: "ConjureSentryDSN") as? String ?? ""

enum SentrySetup {
    static func start() {
        // A DSN pasted into the xcconfig without the $() escape is truncated
        // at "//" to a non-empty "https:", so emptiness alone can't gate.
        guard sentryDSN.contains("@") else {
            if !sentryDSN.isEmpty {
                NSLog("SentrySetup: ConjureSentryDSN looks malformed (no '@') — crash reporting disabled. In the xcconfig, escape '//' as https:/$()/")
            }
            return
        }
        SentrySDK.start { options in
            options.dsn = sentryDSN
            options.enableUncaughtNSExceptionReporting = true
            options.enableAutoSessionTracking = true
            options.attachStacktrace = true
            options.maxBreadcrumbs = 50
            #if DEBUG
            options.environment = "debug"
            options.debug = true
            #else
            options.environment = "release"
            #endif
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                options.releaseName = "com.MichaelJancsy.ConjureDSP@\(version)"
            }
        }
    }
}
