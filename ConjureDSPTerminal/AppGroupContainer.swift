import Darwin
import Foundation

/// Single point of truth for the shared container URL.
///
/// The terminal companion is NOT sandboxed, so accessing ~/Library/Group Containers/
/// triggers macOS 26 TCC "access data from other apps" prompts. Primary storage
/// uses ~/Library/Application Support/ConjureDSP/ (no TCC prompt).
///
/// `groupContainersURL` provides write-through access to Group Containers so
/// DAW-hosted (sandboxed) extensions can find provisioned runtimes.
enum AppGroupContainer {
    static let id = "group.com.MichaelJancsy.ConjureDSP"

    /// Primary location — Application Support (no TCC prompt).
    static let url: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let url = appSupport.appendingPathComponent("ConjureDSP")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Group Containers URL for write-through to DAW-accessible location.
    /// Accessing this WILL trigger a TCC prompt on macOS 26 from unsandboxed processes.
    static let groupContainersURL: URL = {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(id)
    }()
}
