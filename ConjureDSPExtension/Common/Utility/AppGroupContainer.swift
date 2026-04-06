import Foundation

/// Single point of truth for the shared container URL.
///
/// Routes based on sandbox status to avoid macOS 26 TCC "access data from
/// other apps" prompts:
/// - **Sandboxed** (extension in a DAW): Group Containers — the App Group
///   entitlement grants automatic access, no TCC prompt.
/// - **Unsandboxed** (host app, development): Application Support — standard
///   app storage, never TCC-prompted.
enum AppGroupContainer {
    static let id = "group.com.MichaelJancsy.ConjureDSP"

    /// Whether the current process is running inside an App Sandbox.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static let url: URL = {
        if isSandboxed {
            // In a DAW — use Group Containers (sandbox + entitlement = no TCC prompt)
            if let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: id
            ) {
                return url
            }
        }
        // Unsandboxed (host app) — use Application Support (no TCC prompt)
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let url = appSupport.appendingPathComponent("ConjureDSP")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
