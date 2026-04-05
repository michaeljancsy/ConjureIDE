import Darwin
import Foundation

/// Single point of truth for the App Group container URL.
///
/// Uses direct path construction to avoid calling
/// `containerURL(forSecurityApplicationGroupIdentifier:)`, which triggers
/// a TCC "access data from other apps" prompt on macOS 26 when the
/// host process is not sandboxed (most DAWs, and our own host app).
///
/// NOTE: The AU extension runs in a containerized XPC process where
/// `homeDirectoryForCurrentUser` returns the container home (e.g.
/// `~/Library/Containers/<bundleId>/Data/`), NOT the real user home.
/// We use `getpwuid(getuid())` to get the real home from the system
/// passwd database, which always returns `/Users/<username>/`.
enum AppGroupContainer {
    static let id = "group.com.MichaelJancsy.ConjureDSP"
    static let url: URL = {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            // Fallback (should never happen)
            home = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(id)
    }()
}
