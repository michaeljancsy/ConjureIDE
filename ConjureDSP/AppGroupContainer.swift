import Foundation

/// Single point of truth for the shared container URL.
///
/// The host app is NOT sandboxed, so accessing ~/Library/Group Containers/
/// triggers macOS 26 TCC "access data from other apps" prompts. Instead,
/// use ~/Library/Application Support/ConjureDSP/ which is never TCC-prompted.
enum AppGroupContainer {
    static let id = "group.com.MichaelJancsy.ConjureDSP"
    static let url: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let url = appSupport.appendingPathComponent("ConjureDSP")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
