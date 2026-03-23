import Sentry

let sentryDSN = "https://b391e06f4a671b77ae37b94a1160f2bd@o4511091371081728.ingest.us.sentry.io/4511091374030848"

enum SentrySetup {
    static func start() {
        SentrySDK.start { options in
            options.dsn = sentryDSN
            options.enableUncaughtNSExceptionReporting = true
            #if DEBUG
            options.environment = "debug"
            options.debug = true
            #else
            options.environment = "release"
            #endif
        }
    }
}
