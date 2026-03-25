//
//  SharedPythonRuntimeInstaller.swift
//  ConjureDSP
//
//  Copies the Python stdlib+numpy+scipy from the bundled AU extension to a shared location
//  so exported Python AUs can find it without bundling ~130MB per export.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PythonRuntime")

enum SharedPythonRuntimeInstaller {
    static let runtimeVersion = "3.14"

    static var sharedRuntimeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ConjureDSP/PythonRuntime-\(runtimeVersion)")
    }

    /// True if the shared Python runtime (stdlib + numpy) is already installed.
    static var isInstalled: Bool {
        let stdlibPath = sharedRuntimeURL.appendingPathComponent("lib/python3.14t").path
        return FileManager.default.fileExists(atPath: stdlibPath)
    }

    /// Copies the Python stdlib from the bundled AU extension to the shared location.
    /// No-op if already installed. Safe to call from any thread.
    static func installIfNeeded() {
        guard !isInstalled else {
            log.info("Shared Python runtime already installed")
            return
        }

        guard let sourceURL = findBundledPythonDist() else {
            log.error("Cannot install shared runtime: bundled python-dist not found in extension")
            return
        }

        do {
            let fm = FileManager.default
            let destURL = sharedRuntimeURL

            // Create parent directories
            try fm.createDirectory(at: destURL, withIntermediateDirectories: true)

            // Copy lib/python3.14t/ (stdlib + site-packages with numpy+scipy)
            let sourceLib = sourceURL.appendingPathComponent("lib/python3.14t")
            let destLib = destURL.appendingPathComponent("lib/python3.14t")

            if fm.fileExists(atPath: destLib.path) {
                try fm.removeItem(at: destLib)
            }

            // Create lib/ directory
            try fm.createDirectory(at: destURL.appendingPathComponent("lib"), withIntermediateDirectories: true)

            try fm.copyItem(at: sourceLib, to: destLib)

            log.info("Shared Python runtime installed at \(destURL.path, privacy: .public)")
        } catch {
            log.error("Failed to install shared Python runtime: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Finds the bundled python-dist inside the AU extension embedded in this host app.
    private static func findBundledPythonDist() -> URL? {
        let bundle = Bundle.main
        let plugInsURL = bundle.bundleURL.appendingPathComponent("Contents/PlugIns")
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil) else {
            return nil
        }

        for item in contents where item.pathExtension == "appex" {
            let pythonDist = item.appendingPathComponent("Contents/Resources/python-dist")
            if fm.fileExists(atPath: pythonDist.path) {
                return pythonDist
            }
        }

        return nil
    }
}
