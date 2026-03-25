//
//  LicenseManager.swift
//  ConjureDSPExtension
//
//  Manages license verification and persistence.
//  License file is stored at ~/Library/Application Support/ConjureDSP/license.key
//  and contains the raw serial string. This is a machine-level setting,
//  not per-DAW-project (not in fullState).
//

import Combine
import CryptoKit
import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "LicenseManager")

@MainActor
class LicenseManager: ObservableObject {
    @Published private(set) var isLicensed: Bool = false
    @Published private(set) var demoSecondsRemaining: Double = 60.0

    private let licenseFileURL: URL
    private let fileManager = FileManager.default

    /// Closure that calls dsp_kernel_verify_license and returns success.
    var verifyWithKernel: ((String) -> Bool)?

    /// Closure that calls dsp_kernel_demo_seconds_remaining.
    var getDemoSecondsRemaining: (() -> Double)?

    /// Closure that calls dsp_kernel_reset_demo.
    var resetDemoInKernel: (() -> Void)?

    /// Timer for updating demo countdown in UI.
    private var demoTimer: Timer?

    init() {
        let appSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bearBoneDir = appSupport.appendingPathComponent("ConjureDSP", isDirectory: true)
        self.licenseFileURL = bearBoneDir.appendingPathComponent("license.key")

        // Ensure directory exists
        if !fileManager.fileExists(atPath: bearBoneDir.path) {
            try? fileManager.createDirectory(at: bearBoneDir, withIntermediateDirectories: true)
        }
    }

    /// Testable initializer with explicit URL.
    init(licenseFileURL: URL) {
        self.licenseFileURL = licenseFileURL
    }

    /// Load persisted license and verify with kernel.
    func loadAndVerify() {
        guard let serial = loadLicense() else {
            log.info("No persisted license found")
            startDemoTimer()
            return
        }
        let valid = verifyWithKernel?(serial) ?? false
        isLicensed = valid
        if valid {
            log.info("Persisted license verified successfully")
            stopDemoTimer()
        } else {
            log.warning("Persisted license failed verification")
            startDemoTimer()
        }
    }

    /// Verify a serial entered by the user. Persists on success.
    func activate(serial: String) -> Bool {
        let valid = verifyWithKernel?(serial) ?? false
        isLicensed = valid
        Analytics.track(.licenseActivate, properties: ["success": valid])
        if valid {
            do {
                try saveLicense(serial)
                log.info("License activated and saved")
                stopDemoTimer()
                let hash = SHA256.hash(data: Data(serial.utf8))
                let hashString = hash.map { String(format: "%02x", $0) }.joined()
                Analytics.identify(licenseHash: hashString)
            } catch {
                log.error("Failed to save license: \(error.localizedDescription, privacy: .public)")
            }
        }
        Analytics.flush()
        return valid
    }

    /// Reset the demo counter in the kernel, giving another 60 seconds.
    func restartDemo() {
        resetDemoInKernel?()
        updateDemoTime()
    }

    // MARK: - File I/O

    func loadLicense() -> String? {
        guard let data = fileManager.contents(atPath: licenseFileURL.path),
              let serial = String(data: data, encoding: .utf8) else {
            return nil
        }
        return serial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveLicense(_ serial: String) throws {
        let dir = licenseFileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try serial.write(to: licenseFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Demo Timer

    private func startDemoTimer() {
        guard demoTimer == nil else { return }
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateDemoTime()
            }
        }
    }

    private func stopDemoTimer() {
        demoTimer?.invalidate()
        demoTimer = nil
    }

    private func updateDemoTime() {
        demoSecondsRemaining = getDemoSecondsRemaining?() ?? 0
    }
}
