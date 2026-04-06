import Foundation

/// Test copy of AppGroupContainer — mirrors the production implementation.
/// Tests run unsandboxed, so this uses Application Support (no TCC prompt).
enum AppGroupContainer {
    static let id = "group.com.MichaelJancsy.ConjureDSP"

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static let url: URL = {
        if isSandboxed {
            if let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: id
            ) {
                return url
            }
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let url = appSupport.appendingPathComponent("ConjureDSP")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
