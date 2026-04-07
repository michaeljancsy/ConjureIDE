import Sentry

let sentryDSN = "https://b391e06f4a671b77ae37b94a1160f2bd@o4511091371081728.ingest.us.sentry.io/4511091374030848"

enum SentrySetup {
    static func start() {
        SentrySDK.start { options in
            options.dsn = sentryDSN
            options.enableUncaughtNSExceptionReporting = true
            options.enableAutoSessionTracking = true
            options.attachStacktrace = true
            options.maxBreadcrumbs = 50
            #if DEBUG
            options.environment = "debug-terminal"
            options.debug = true
            #else
            options.environment = "release-terminal"
            #endif
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                options.releaseName = "com.MichaelJancsy.ConjureDSP.Terminal@\(version)"
            }
        }
    }
}
