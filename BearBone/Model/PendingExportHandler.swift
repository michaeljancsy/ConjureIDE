import AppKit
import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "PendingExportHandler")

/// Handles pending AU exports staged in the App Group container by the AU extension.
///
/// On launch, checks for `.app` bundles in the App Group's `PendingExports/` directory.
/// For each: moves to `~/Library/Application Support/BearBone/Exports/`, code signs,
/// launches (to register AU with macOS), reveals in Finder, and cleans up.
final class PendingExportHandler: ObservableObject {
    static let appGroupIdentifier = "group.com.MichaelJancsy.BearBone"

    @Published var installedExportName: String?
    @Published var installError: String?

    private var exportsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("BearBone/Exports")
    }

    private var pendingExportsDirectory: URL? {
        // The host app is NOT sandboxed, so it can access the Group Containers path
        // directly without needing the App Group entitlement. The AU extension writes
        // here using its App Group entitlement when running sandboxed in a DAW.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let groupContainer = home
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(Self.appGroupIdentifier)
            .appendingPathComponent("PendingExports")
        return groupContainer
    }

    func checkForPendingExports() {
        guard let pendingDir = pendingExportsDirectory else {
            log.info("No App Group container available")
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: pendingDir.path) else {
            return
        }

        guard let contents = try? fm.contentsOfDirectory(
            at: pendingDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let appBundles = contents.filter { $0.pathExtension == "app" }
        guard !appBundles.isEmpty else { return }

        log.info("Found \(appBundles.count) pending export(s)")

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
        process.arguments = ["-s", "-", "--force", "--timestamp=none", "--deep", url.path]

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

    private func registerWithLaunchServices(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister")
        process.arguments = ["-f", "-R", "-trusted", url.path]
        try? process.run()
        process.waitUntilExit()
    }
}
