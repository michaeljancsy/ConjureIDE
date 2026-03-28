//
//  PackageInstaller.swift
//  ConjureDSPTerminal
//
//  Watches for package install/uninstall requests in the App Group container
//  and executes them using the bundled `uv` package manager.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.Terminal", category: "PackageInstaller")

final class PackageInstaller {
    private let appGroupURL: URL
    private let uvPath: String

    private static let installRequestFile = "package-install-request.json"
    private static let uninstallRequestFile = "package-uninstall-request.json"
    private static let installResultFile = "package-install-result.json"

    // MARK: - Request/Result models (must match PackageInstallManager in the extension)

    struct InstallRequest: Codable {
        let packages: [String]
        let targetPath: String
        let pythonHomePath: String
        let timestamp: Double
    }

    struct UninstallRequest: Codable {
        let packages: [String]
        let targetPath: String
        let timestamp: Double
    }

    struct InstallResult: Codable {
        let success: Bool
        let packages: [String]
        let error: String?
        let timestamp: Double
    }

    // MARK: - Init

    init?(appGroupURL: URL) {
        self.appGroupURL = appGroupURL

        // Find bundled uv binary
        if let resourceURL = Bundle.main.resourceURL {
            let bundledUV = resourceURL.appendingPathComponent("uv").path
            if FileManager.default.fileExists(atPath: bundledUV) {
                self.uvPath = bundledUV
                return
            }
        }

        // Fallback: check if uv is on PATH
        let whichResult = Self.runProcessSync("/usr/bin/which", arguments: ["uv"])
        if let path = whichResult.output?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            self.uvPath = path
            return
        }

        log.error("uv binary not found — package installation unavailable")
        return nil
    }

    // MARK: - Check for requests

    /// Called from the file-watch loop. Checks for and processes pending requests.
    func checkForRequests() async {
        await checkForInstallRequest()
        await checkForUninstallRequest()
    }

    private func checkForInstallRequest() async {
        let requestURL = appGroupURL.appendingPathComponent(Self.installRequestFile)
        guard FileManager.default.fileExists(atPath: requestURL.path),
              let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(InstallRequest.self, from: data)
        else { return }

        // Remove request file immediately to avoid re-processing
        try? FileManager.default.removeItem(at: requestURL)

        log.info("Processing install request: \(request.packages.joined(separator: ", "), privacy: .public)")

        do {
            try await installPackages(request)
            writeResult(InstallResult(
                success: true,
                packages: request.packages,
                error: nil,
                timestamp: Date().timeIntervalSince1970
            ))
            log.info("Install succeeded for: \(request.packages.joined(separator: ", "), privacy: .public)")
        } catch {
            writeResult(InstallResult(
                success: false,
                packages: request.packages,
                error: error.localizedDescription,
                timestamp: Date().timeIntervalSince1970
            ))
            log.error("Install failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func checkForUninstallRequest() async {
        let requestURL = appGroupURL.appendingPathComponent(Self.uninstallRequestFile)
        guard FileManager.default.fileExists(atPath: requestURL.path),
              let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(UninstallRequest.self, from: data)
        else { return }

        try? FileManager.default.removeItem(at: requestURL)

        log.info("Processing uninstall request: \(request.packages.joined(separator: ", "), privacy: .public)")

        do {
            try uninstallPackages(request)
            writeResult(InstallResult(
                success: true,
                packages: request.packages,
                error: nil,
                timestamp: Date().timeIntervalSince1970
            ))
            log.info("Uninstall succeeded for: \(request.packages.joined(separator: ", "), privacy: .public)")
        } catch {
            writeResult(InstallResult(
                success: false,
                packages: request.packages,
                error: error.localizedDescription,
                timestamp: Date().timeIntervalSince1970
            ))
            log.error("Uninstall failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Install

    private func installPackages(_ request: InstallRequest) async throws {
        let fm = FileManager.default

        // Ensure target directory exists
        try fm.createDirectory(atPath: request.targetPath, withIntermediateDirectories: true)

        // Build uv command
        let pythonBin = request.pythonHomePath + "/bin/python3"
        var args = ["pip", "install",
                    "--target", request.targetPath,
                    "--python", pythonBin]
        args.append(contentsOf: request.packages)

        let result = await Self.runProcess(uvPath, arguments: args)

        if result.exitCode != 0 {
            let errMsg = result.output ?? "uv exited with code \(result.exitCode)"
            throw PackageInstallerError.installFailed(errMsg)
        }

        // Code-sign any .so and .dylib files for hardened runtime
        try await codeSignDynamicLibraries(in: URL(fileURLWithPath: request.targetPath))
    }

    // MARK: - Uninstall

    private func uninstallPackages(_ request: UninstallRequest) throws {
        let fm = FileManager.default
        let targetURL = URL(fileURLWithPath: request.targetPath)

        for packageName in request.packages {
            // Remove package directory
            let normalizedName = packageName.lowercased().replacingOccurrences(of: "-", with: "_")
            let pkgDir = targetURL.appendingPathComponent(normalizedName)
            if fm.fileExists(atPath: pkgDir.path) {
                try fm.removeItem(at: pkgDir)
            }

            // Remove .dist-info directory
            if let contents = try? fm.contentsOfDirectory(at: targetURL, includingPropertiesForKeys: nil) {
                for item in contents {
                    let name = item.lastPathComponent
                    if name.hasSuffix(".dist-info"),
                       name.lowercased().hasPrefix(normalizedName + "-") {
                        try fm.removeItem(at: item)
                    }
                }
            }
        }
    }

    // MARK: - Code signing

    private func codeSignDynamicLibraries(in directory: URL) async throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension
            if ext == "so" || ext == "dylib" {
                let result = await Self.runProcess("/usr/bin/codesign",
                    arguments: ["--force", "--sign", "-", fileURL.path])
                if result.exitCode != 0 {
                    log.warning("Code-sign failed for \(fileURL.lastPathComponent, privacy: .public): \(result.output ?? "", privacy: .public)")
                }
            }
        }
    }

    // MARK: - Result file

    private func writeResult(_ result: InstallResult) {
        let resultURL = appGroupURL.appendingPathComponent(Self.installResultFile)
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: resultURL, options: .atomic)
        }
    }

    // MARK: - Process execution

    /// Synchronous variant for use during init (before async context is available).
    private static func runProcessSync(_ path: String, arguments: [String]) -> (exitCode: Int32, output: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8))
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private static func runProcess(_ path: String, arguments: [String]) async -> (exitCode: Int32, output: String?) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)
                continuation.resume(returning: (process.terminationStatus, output))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    // MARK: - Errors

    enum PackageInstallerError: LocalizedError {
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .installFailed(let msg): return msg
            }
        }
    }
}
