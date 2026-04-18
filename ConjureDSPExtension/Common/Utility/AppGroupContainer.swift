import Foundation

/// Single point of truth for the shared container URL.
///
/// Routes based on process context to avoid macOS 26 TCC "access data from
/// other apps" prompts:
/// - **Appex process** (view service, whether hosted by ConjureDSP host app or
///   a DAW): Group Containers — the App Group entitlement grants automatic
///   access, no TCC prompt, and the path is shared with the daemon.
/// - **Host app process** (AU loaded in-process via `.loadInProcess`, or host
///   app code using extension types): Application Support — standard app
///   storage, never TCC-prompted. The unsandboxed host's Application Support
///   resolves to the real user directory, same as the daemon.
///
/// Detection uses `Bundle.main.bundlePath` to check whether we're in an appex
/// process. When the AU view service runs out-of-process, Bundle.main points
/// to the .appex bundle. When code runs in-process in the host app, Bundle.main
/// points to the .app bundle. This is more reliable than checking bundle IDs
/// (the extension's ID has the host app's ID as a prefix) or
/// APP_SANDBOX_CONTAINER_ID (set even for `.loadInProcess` hosting).
enum AppGroupContainer {
    static let id = "group.com.MichaelJancsy.ConjureDSP"

    /// Whether the current process is the host app (not a sandboxed appex).
    /// When true, Application Support resolves to the real user directory.
    /// When false, we must use Group Containers for cross-process visibility.
    private static var isRunningInHostProcess: Bool {
        // Appex view service: Bundle.main.bundlePath ends with ".appex"
        // Host app process: Bundle.main.bundlePath ends with ".app"
        !Bundle.main.bundlePath.hasSuffix(".appex")
    }

    static let url: URL = {
        if !isRunningInHostProcess {
            // Appex process (sandboxed) — use Group Containers for cross-process visibility
            if let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: id
            ) {
                // Strip quarantine on the container root only. Walking
                // deeper is fatal at startup: WasmCache has 2000+ entries
                // and Presets/.git has hundreds of object dirs — the
                // enumeration blows the AU instantiation XPC timeout
                // (~2s) and the host gives up with "Failed to open
                // AudioUnit extension: Client is gone". Per-write strips
                // in PresetManager handle subdirectories going forward.
                stripQuarantine(at: url)
                return url
            }
        }
        // Host app process or fallback — use Application Support (no TCC prompt)
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let url = appSupport.appendingPathComponent("ConjureDSP")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Remove the `com.apple.quarantine` xattr from `url` if present. macOS
    /// 26 sets this xattr on files a sandboxed appex creates in its Group
    /// Container; when a different-signed version of the appex (e.g. Debug
    /// → Release, or a fresh dev build with rotated signing) later tries
    /// to write, macOS compares signatures and denies with "You don't
    /// have permission to save the file X in the folder Y." Stripping
    /// removes the comparison point and future writes succeed.
    ///
    /// Silent no-op if the xattr isn't present, if we don't own the file,
    /// or if the sandbox blocks the removal — best effort by design.
    static func stripQuarantine(at url: URL) {
        _ = url.path.withCString { removexattr($0, "com.apple.quarantine", 0) }
    }
}
