//
//  DaemonStatusChecker.swift
//  ConjureDSPExtension
//
//  Polls the App Group container for the terminal-server-port file
//  to determine whether the ConjureDSP Terminal daemon is running.
//

import Combine
import Foundation
import os

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension", category: "DaemonStatusChecker")

@MainActor
final class DaemonStatusChecker: ObservableObject {
    @Published private(set) var isDaemonAvailable: Bool = false

    private let appGroupID = "group.com.MichaelJancsy.ConjureDSP"
    private var timer: Timer?

    func startChecking() {
        // Check immediately
        isDaemonAvailable = checkPortFile()
        log.info("Daemon status check started, available: \(self.isDaemonAvailable)")

        // Poll every 2 seconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let available = self.checkPortFile()
                if available != self.isDaemonAvailable {
                    log.info("Daemon availability changed: \(available)")
                    self.isDaemonAvailable = available
                }
            }
        }
    }

    func stopChecking() {
        timer?.invalidate()
        timer = nil
    }

    private func checkPortFile() -> Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return false }

        let portFile = container.appendingPathComponent("terminal-server-port")
        guard let contents = try? String(contentsOf: portFile, encoding: .utf8),
              let port = UInt16(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0 else {
            return false
        }
        return true
    }
}
