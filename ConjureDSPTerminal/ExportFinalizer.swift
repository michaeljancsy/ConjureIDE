//
//  ExportFinalizer.swift
//  ConjureDSPTerminal
//
//  Watches for unsigned AU export bundles in the App Group container's
//  PendingExports/ directory and finalizes them: code sign, remove
//  quarantine, register with LaunchServices, and reveal in Finder.
//

import AppKit
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.Terminal", category: "ExportFinalizer")

final class ExportFinalizer {
    let appGroupURL: URL

    private var exportsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ConjureDSP/Exports")
    }

    init(appGroupURL: URL) {
        self.appGroupURL = appGroupURL
    }

    /// Called from the file-watch loop. Checks the App Group container for pending exports.
    func checkForPendingExports() async {
        await processExportsIn(appGroupURL.appendingPathComponent("PendingExports"))
    }

    private func processExportsIn(_ directory: URL) async {
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
            await installExport(at: appURL)
        }
    }

    private func installExport(at sourceURL: URL) async {
        let fm = FileManager.default
        let name = sourceURL.deletingPathExtension().lastPathComponent

        do {
            try fm.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)

            let destURL = exportsDirectory.appendingPathComponent(sourceURL.lastPathComponent)

            // Remove previous version if exists
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }

            // Move from App Group staging to permanent location
            try fm.moveItem(at: sourceURL, to: destURL)
            log.info("Moved export to \(destURL.path, privacy: .public)")

            // Code sign (deepest first: frameworks → appex → app)
            let appexes = try fm.contentsOfDirectory(
                at: destURL.appendingPathComponent("Contents/PlugIns"),
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "appex" }

            for appex in appexes {
                let frameworks = appex.appendingPathComponent("Contents/Frameworks")
                if fm.fileExists(atPath: frameworks.path) {
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
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([destURL])
            }

            // Notify extension of success
            postResult(name: name, success: true, error: nil)
        } catch {
            log.error("Failed to install export '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            postResult(name: name, success: false, error: error.localizedDescription)
        }
    }

    // MARK: - Code signing

    private func codeSign(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-s", "-", "--force", "--timestamp=none",
                             "--preserve-metadata=entitlements", url.path]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "ExportFinalizer",
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

    // MARK: - Notification

    private func postResult(name: String, success: Bool, error: String?) {
        var userInfo: [String: String] = [
            "name": name,
            "success": success ? "true" : "false",
        ]
        if let error {
            userInfo["error"] = error
        }

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.MichaelJancsy.ConjureDSP.exportFinalized"),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}
