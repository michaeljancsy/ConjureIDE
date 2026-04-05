import Darwin
import Foundation

/// Test copy of AppGroupContainer — uses getpwuid to get the real home
/// directory (same as the extension's production implementation).
enum AppGroupContainer {
    static let id = "group.com.MichaelJancsy.ConjureDSP"
    static let url: URL = {
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
