import Foundation
import Sentry

enum SentryHelper {
    enum Level {
        case error
        case warning
        case info

        var sentryLevel: SentryLevel {
            switch self {
            case .error: return .error
            case .warning: return .warning
            case .info: return .info
            }
        }
    }

    static func capture(
        _ message: String,
        level: Level = .error,
        category: String,
        extra: [String: Any]? = nil
    ) {
        #if DEBUG
        return
        #else
        let event = Event(level: level.sentryLevel)
        event.message = SentryMessage(formatted: message)
        event.tags = ["category": category]
        if let extra { event.extra = extra }
        SentrySDK.capture(event: event)
        #endif
    }

    static func captureError(
        _ error: Error,
        category: String,
        extra: [String: Any]? = nil
    ) {
        #if DEBUG
        return
        #else
        SentrySDK.configureScope { scope in
            scope.setTag(value: category, key: "category")
            if let extra {
                for (key, value) in extra {
                    scope.setExtra(value: value, key: key)
                }
            }
        }
        SentrySDK.capture(error: error)
        SentrySDK.configureScope { scope in
            scope.removeTag(key: "category")
            if let extra {
                for key in extra.keys {
                    scope.removeExtra(key: key)
                }
            }
        }
        #endif
    }

    static func breadcrumb(
        _ message: String,
        category: String,
        data: [String: Any]? = nil
    ) {
        #if DEBUG
        return
        #else
        let crumb = Breadcrumb(level: .info, category: category)
        crumb.message = message
        crumb.data = data
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }
}
