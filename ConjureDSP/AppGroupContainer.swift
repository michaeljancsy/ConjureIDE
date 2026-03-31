import Foundation

/// Single point of truth for the App Group container URL.
///
/// The host app is NOT sandboxed, so it can access the group container
/// via a direct path. This avoids calling `containerURL(forSecurityApplicationGroupIdentifier:)`,
/// which triggers a TCC "access data from other apps" prompt on macOS 26.
/// The sandboxed extension (ConjureDSPExtension) uses the API-based approach instead.
enum AppGroupContainer {
    static let id = "group.com.MichaelJancsy.ConjureDSP"
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers")
        .appendingPathComponent(id)
}
