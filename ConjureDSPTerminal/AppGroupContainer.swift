import Foundation

/// Single point of truth for the App Group container URL.
/// Resolves once on first access (thread-safe via `static let`);
/// subsequent reads return the cached value without triggering TCC prompts.
enum AppGroupContainer {
    static let id = "group.com.MichaelJancsy.ConjureDSP"
    static let url: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: id
    )
}
