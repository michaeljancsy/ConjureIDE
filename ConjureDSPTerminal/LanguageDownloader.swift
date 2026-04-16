//
//  LanguageDownloader.swift
//  ConjureDSPTerminal
//
//  Companion-app worker that picks up language-module install/uninstall
//  requests from the App Group container, downloads the tarball, verifies
//  its SHA256 (and optionally the Developer ID code signature of any
//  contained dylibs/executables), extracts it to LanguageModules/<name>/,
//  writes a local manifest, and reports back via the result file.
//
//  Runs outside the AU extension's sandbox so it can do large network I/O
//  and spawn external binaries like `shasum` and `tar` / `ditto`.
//

import Foundation
import CryptoKit
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.Terminal", category: "LanguageDownloader")

enum LanguageDownloaderError: LocalizedError {
    case downloadFailed(Int)
    case sha256Mismatch(expected: String, actual: String)
    case extractionFailed(String)
    case signatureFailed(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let code):
            return "Download failed (HTTP \(code))"
        case .sha256Mismatch(let expected, let actual):
            return "SHA256 mismatch — expected \(expected), got \(actual)"
        case .extractionFailed(let detail):
            return "Extraction failed: \(detail)"
        case .signatureFailed(let detail):
            return "Signature check failed: \(detail)"
        case .invalidURL:
            return "Invalid tarball URL"
        }
    }
}

final class LanguageDownloader {
    let appGroupURL: URL
    private let modulesDirURL: URL

    /// Whether to enforce Developer ID code-signature verification on
    /// extracted dylibs/executables. Off by default for Phase 1 so
    /// in-dev test modules can be unsigned; flip to true once the module
    /// build pipeline signs everything.
    var enforceCodesign: Bool {
        // Allow override via UserDefaults for local testing.
        if UserDefaults.standard.object(forKey: "ConjureDSPEnforceCodesign") != nil {
            return UserDefaults.standard.bool(forKey: "ConjureDSPEnforceCodesign")
        }
        return false
    }

    init(appGroupURL: URL) {
        self.appGroupURL = appGroupURL
        self.modulesDirURL = appGroupURL.appendingPathComponent(LanguageModuleIPC.modulesDirectory)
        try? FileManager.default.createDirectory(at: modulesDirURL, withIntermediateDirectories: true)
        log.info("LanguageDownloader ready — modules dir = \(self.modulesDirURL.path, privacy: .public)")
    }

    // MARK: - Poll entry point

    /// Called every ~500ms from the companion app's main loop. Handles at most
    /// one install and one uninstall per tick.
    func checkForRequests() async {
        await checkForInstallRequest()
        await checkForUninstallRequest()
    }

    // MARK: - Install

    private func checkForInstallRequest() async {
        let requestURL = appGroupURL.appendingPathComponent(LanguageModuleIPC.installRequestFile)
        guard FileManager.default.fileExists(atPath: requestURL.path),
              let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(LanguageInstallRequest.self, from: data)
        else { return }

        try? FileManager.default.removeItem(at: requestURL)
        clearProgress()
        log.info("Processing install request for \(request.moduleName, privacy: .public) \(request.version, privacy: .public)")

        do {
            try await installModule(request)
            writeResult(LanguageInstallResult(
                requestId: request.requestId,
                moduleName: request.moduleName,
                success: true,
                error: nil,
                timestamp: Date().timeIntervalSince1970
            ))
            log.info("Install succeeded: \(request.moduleName, privacy: .public)")
        } catch {
            writeResult(LanguageInstallResult(
                requestId: request.requestId,
                moduleName: request.moduleName,
                success: false,
                error: error.localizedDescription,
                timestamp: Date().timeIntervalSince1970
            ))
            log.error("Install failed: \(error.localizedDescription, privacy: .public)")
        }
        clearProgress()
    }

    private func installModule(_ request: LanguageInstallRequest) async throws {
        guard let tarballURL = URL(string: request.url) else {
            throw LanguageDownloaderError.invalidURL
        }
        let moduleDir = modulesDirURL.appendingPathComponent(request.moduleName)

        // 1. Download to a temp file with progress reporting
        writeProgress("Downloading \(request.moduleName)...")
        let tempURL = try await download(from: tarballURL, progressLabel: request.moduleName)

        // 2. Verify SHA256
        writeProgress("Verifying \(request.moduleName)...")
        let actualSha = try sha256Hex(of: tempURL)
        if actualSha.lowercased() != request.sha256.lowercased() {
            try? FileManager.default.removeItem(at: tempURL)
            throw LanguageDownloaderError.sha256Mismatch(expected: request.sha256, actual: actualSha)
        }

        // 3. Extract into a staging directory, then atomic-swap.
        // Staging pattern guards against partial extracts leaving a module
        // half-installed if something dies mid-flight.
        writeProgress("Extracting \(request.moduleName)...")
        let stagingDir = modulesDirURL.appendingPathComponent(".staging-\(request.moduleName)-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.removeItem(at: stagingDir)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        do {
            try extractTarball(at: tempURL, into: stagingDir)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // 4. (Optional) Verify code signatures
        if enforceCodesign {
            writeProgress("Verifying signature of \(request.moduleName)...")
            try verifyCodeSignatures(in: stagingDir)
        }

        // 5. Measure installed size for the manifest
        let installedBytes = (try? directorySize(at: stagingDir)) ?? 0

        // 6. Write local manifest
        let manifest = InstalledLanguageModuleManifest(
            name: request.moduleName,
            version: request.version,
            installedAt: Date().timeIntervalSince1970,
            sha256: request.sha256,
            installedBytes: installedBytes,
            entrypoints: [:]
        )
        let manifestURL = stagingDir.appendingPathComponent(LanguageModuleIPC.manifestFile)
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        // 7. Atomic swap: remove existing module dir (if any), move staging into place.
        try? FileManager.default.removeItem(at: moduleDir)
        try FileManager.default.moveItem(at: stagingDir, to: moduleDir)

        // 8. Cleanup tarball
        try? FileManager.default.removeItem(at: tempURL)

        log.info("Installed \(request.moduleName, privacy: .public) (\(installedBytes) bytes)")
    }

    // MARK: - Uninstall

    private func checkForUninstallRequest() async {
        let requestURL = appGroupURL.appendingPathComponent(LanguageModuleIPC.uninstallRequestFile)
        guard FileManager.default.fileExists(atPath: requestURL.path),
              let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(LanguageUninstallRequest.self, from: data)
        else { return }

        try? FileManager.default.removeItem(at: requestURL)
        log.info("Processing uninstall request for \(request.moduleName, privacy: .public)")

        let moduleDir = modulesDirURL.appendingPathComponent(request.moduleName)
        do {
            if FileManager.default.fileExists(atPath: moduleDir.path) {
                try FileManager.default.removeItem(at: moduleDir)
            }
            writeResult(LanguageInstallResult(
                requestId: request.requestId,
                moduleName: request.moduleName,
                success: true,
                error: nil,
                timestamp: Date().timeIntervalSince1970
            ))
            log.info("Uninstalled \(request.moduleName, privacy: .public)")
        } catch {
            writeResult(LanguageInstallResult(
                requestId: request.requestId,
                moduleName: request.moduleName,
                success: false,
                error: error.localizedDescription,
                timestamp: Date().timeIntervalSince1970
            ))
            log.error("Uninstall failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Download (with progress)

    private func download(from url: URL, progressLabel: String) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw LanguageDownloaderError.downloadFailed(http.statusCode)
        }
        // Move into our own temp location so the URLSession-owned file is released.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(progressLabel)-\(UUID().uuidString).tar.gz")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // MARK: - SHA256

    private func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Extraction

    private func extractTarball(at tarballURL: URL, into destination: URL) throws {
        // Use `tar` from the system. Equivalent of `tar -xzf <tarball> -C <dest>`.
        // `ditto -x -k` is fine for .zip but not .tar.gz; stick with tar.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tarballURL.path, "-C", destination.path]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "(no stderr)"
            throw LanguageDownloaderError.extractionFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Code signature verification

    private func verifyCodeSignatures(in directory: URL) throws {
        // Walk the extracted tree; for each Mach-O binary (dylib, executable),
        // run `codesign --verify --deep --strict`. A failure anywhere aborts.
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey]
        ) else { return }

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let looksLikeBinary = (values.isExecutable == true) || ext == "dylib" || ext == "so"
            guard looksLikeBinary else { continue }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--deep", "--strict", url.path]
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = Pipe()
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let msg = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? "(no output)"
                throw LanguageDownloaderError.signatureFailed("\(url.lastPathComponent): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    // MARK: - Directory size

    private func directorySize(at url: URL) throws -> UInt64 {
        var total: UInt64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        for case let entry as URL in enumerator {
            let values = try entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true, let size = values.fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    // MARK: - Result + progress file helpers

    private func writeResult(_ result: LanguageInstallResult) {
        let resultURL = appGroupURL.appendingPathComponent(LanguageModuleIPC.installResultFile)
        do {
            let data = try JSONEncoder().encode(result)
            try data.write(to: resultURL, options: .atomic)
        } catch {
            log.error("Failed to write result: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writeProgress(_ message: String) {
        let progressURL = appGroupURL.appendingPathComponent(LanguageModuleIPC.downloadProgressFile)
        try? message.data(using: .utf8)?.write(to: progressURL, options: .atomic)
    }

    private func clearProgress() {
        let progressURL = appGroupURL.appendingPathComponent(LanguageModuleIPC.downloadProgressFile)
        try? FileManager.default.removeItem(at: progressURL)
    }
}
