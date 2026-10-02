import Foundation
import Sentry

/// Resolves the bundle this file was compiled into — unlike Bundle.main,
/// which is the host DAW's bundle when the AU is loaded in-process.
private final class SentryBundleToken {}

/// Populated from the ConjureSentryDSN Info.plist key, which mirrors the
/// CONJURE_SENTRY_DSN build setting (Config/Local.xcconfig). Empty or missing
/// means crash reporting stays disabled. DEBUG builds never report regardless:
/// they carry the shipped version and build numbers, have no dSYMs to
/// symbolicate against, and run constantly under the debugger and test suites.
#if DEBUG
let sentryDSN = ""
#else
let sentryDSN = Bundle(for: SentryBundleToken.self)
    .object(forInfoDictionaryKey: "ConjureSentryDSN") as? String ?? ""
#endif

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
            options.environment = "release"
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                options.releaseName = "com.MichaelJancsy.ConjureDSP@\(version)"
            }
        }
    }
}
