import AppKit
import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PendingExportHandler")

/// Handles pending AU exports staged in the App Group container by the AU extension.
///
/// On launch, checks for `.app` bundles in the App Group's `PendingExports/` directory.
/// For each: moves to `~/Library/Application Support/ConjureDSP/Exports/`, code signs,
/// launches (to register AU with macOS), reveals in Finder, and cleans up.
final class PendingExportHandler: ObservableObject {
    static let appGroupIdentifier = AppGroupContainer.id

    @Published var installedExportName: String?
    @Published var installError: String?

    private var exportsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ConjureDSP/Exports")
    }

    /// Directory where non-sandboxed contexts (host app) stage exports.
    /// Only checks Application Support — no TCC prompt.
    private var pendingExportsDirectories: [URL] {
        [AppGroupContainer.url.appendingPathComponent("PendingExports")]
    }

    /// Check Group Containers for exports staged by the AU extension running
    /// in a sandboxed context (DAW or ViewBridge XPC).
    ///
    /// This accesses `~/Library/Group Containers/` which triggers a macOS TCC
    /// "access data from other apps" prompt for unsandboxed processes. Only call
    /// when we know an export was staged (via DistributedNotification) or when
    /// the user explicitly requests it.
    func checkGroupContainersForExports() {
        let groupDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(Self.appGroupIdentifier)
            .appendingPathComponent("PendingExports")
        processExportsIn(groupDir)
    }

    private var distributedObserver: NSObjectProtocol?

    /// Listen for DistributedNotification from the AU extension when it stages
    /// an export in Group Containers. Uses Mach ports — no file I/O, no TCC.
    func startListeningForDAWExports() {
        guard distributedObserver == nil else { return }
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.MichaelJancsy.ConjureDSP.pendingExport"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkGroupContainersForExports()
        }
    }

    func checkForPendingExports() {
        for pendingDir in pendingExportsDirectories {
            processExportsIn(pendingDir)
        }
    }

    private func processExportsIn(_ directory: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              let contents = try? fm.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else { return }

        let appBundles = contents.filter { $0.pathExtension == "app" }
        guard !appBundles.isEmpty else { return }

        log.info("Found \(appBundles.count) pending export(s) in \(directory.path, privacy: .public)")

        for appURL in appBundles {
            installExport(at: appURL)
        }
    }

    private func installExport(at sourceURL: URL) {
        let fm = FileManager.default
        let name = sourceURL.deletingPathExtension().lastPathComponent

        do {
            // Ensure exports directory exists
            try fm.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)

            let destURL = exportsDirectory.appendingPathComponent(sourceURL.lastPathComponent)

            // Remove previous version if exists
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }

            // Move from App Group staging to permanent location
            try fm.moveItem(at: sourceURL, to: destURL)
            log.info("Moved export to \(destURL.path, privacy: .public)")

            // Code sign (deepest first)
            let appexGlob = try fm.contentsOfDirectory(
                at: destURL.appendingPathComponent("Contents/PlugIns"),
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "appex" }

            for appex in appexGlob {
                let frameworks = appex.appendingPathComponent("Contents/Frameworks")
                if fm.fileExists(atPath: frameworks.path) {
                    // Sign each item inside Frameworks individually (dylibs, .so files)
                    let frameworkItems = try fm.contentsOfDirectory(
                        at: frameworks, includingPropertiesForKeys: nil
                    )
                    for item in frameworkItems {
                        try codeSign(item)
                    }
                }
                try codeSign(appex)
            }
            try codeSign(destURL)
            log.info("Code signed \(name, privacy: .public)")

            // Remove quarantine attribute so Gatekeeper doesn't block the ad-hoc signed app
            removeQuarantine(destURL)

            // Register with LaunchServices so PluginKit discovers the embedded .appex
            registerWithLaunchServices(destURL)
            log.info("Registered \(name, privacy: .public) with LaunchServices")

            // Reveal in Finder
            NSWorkspace.shared.activateFileViewerSelecting([destURL])

            installedExportName = name
            installError = nil
        } catch {
            log.error("Failed to install export '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            installError = "Failed to install \"\(name)\": \(error.localizedDescription)"
        }
    }

    private func codeSign(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // --preserve-metadata=entitlements: keeps the sandbox entitlements from the
        // Xcode-built template. Without this, ad-hoc signing strips entitlements and
        // PluginKit refuses to register the extension (requires app-sandbox = true).
        // No --deep: caller signs in correct order (frameworks → appex → app).
        process.arguments = ["-s", "-", "--force", "--timestamp=none",
                             "--preserve-metadata=entitlements", url.path]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "PendingExportHandler",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Code signing failed: \(stderr)"]
            )
        }
    }

    private func removeQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    private func registerWithLaunchServices(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister")
        process.arguments = ["-f", "-R", "-trusted", url.path]
        try? process.run()
        process.waitUntilExit()
    }
}
