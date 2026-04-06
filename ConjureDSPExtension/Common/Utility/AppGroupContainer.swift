import Foundation

/// Single point of truth for the shared container URL.
///
/// Routes based on hosting context to avoid macOS 26 TCC "access data from
/// other apps" prompts:
/// - **DAW-hosted** (extension in a DAW's ViewBridge XPC): Group Containers —
///   the App Group entitlement grants automatic access, no TCC prompt.
/// - **Host app** (extension loaded in-process, or host app code): Application
///   Support — standard app storage, never TCC-prompted.
///
/// Detection uses `Bundle.main.bundleIdentifier` rather than
/// `APP_SANDBOX_CONTAINER_ID` because `.loadInProcess` AU hosting can set the
/// sandbox env var even though the host app itself is unsandboxed, which would
/// incorrectly route to Group Containers and trigger TCC prompts.
enum AppGroupContainer {
    static let id = "group.com.MichaelJancsy.ConjureDSP"

    /// Whether the extension is running inside the ConjureDSP host app
    /// (loaded in-process via `.loadInProcess`). When true, we must use
    /// Application Support to avoid TCC prompts from the unsandboxed host.
    private static var isInHostApp: Bool {
        Bundle.main.bundleIdentifier?.hasPrefix("com.MichaelJancsy.ConjureDSP") == true
    }

    static let url: URL = {
        if !isInHostApp {
            // In a DAW — use Group Containers (sandbox + entitlement = no TCC prompt)
            if let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: id
            ) {
                return url
            }
        }
        // Host app or fallback — use Application Support (no TCC prompt)
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let url = appSupport.appendingPathComponent("ConjureDSP")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
