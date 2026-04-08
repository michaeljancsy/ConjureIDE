import Foundation

/// Single point of truth for the shared container URL.
///
/// Uses `containerURL(forSecurityApplicationGroupIdentifier:)` to access the
/// App Group container. This API signals the App Group entitlement to macOS,
/// avoiding macOS 26 TCC "access data from other apps" prompts that occur
/// when constructing the ~/Library/Group Containers/ path manually.
///
/// Both the terminal and the sandboxed AU extension resolve to the same
/// directory via this API, so all shared data (runtimes, port files, presets)
/// is visible to both processes without mirroring.
enum AppGroupContainer {
    static let id = "group.com.MichaelJancsy.ConjureDSP"

    static let url: URL = {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: id
        ) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // Fallback for processes without the App Group entitlement (shouldn't happen).
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let url = appSupport.appendingPathComponent("ConjureDSP")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
