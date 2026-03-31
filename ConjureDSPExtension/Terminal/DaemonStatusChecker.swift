//
//  DaemonStatusChecker.swift
//  ConjureDSPExtension
//
//  Polls the App Group container for the terminal-server-port file
//  to determine whether the ConjureDSP Terminal daemon is running.
//

import Combine
import Darwin
import Foundation
import os

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension", category: "DaemonStatusChecker")

@MainActor
final class DaemonStatusChecker: ObservableObject {
    @Published private(set) var isDaemonAvailable: Bool = false

    private let appGroupID = "group.com.MichaelJancsy.ConjureDSP"
    private let pollInterval: TimeInterval
    private var timer: Timer?

    /// Override for testing — when non-nil, `checkPortFile()` reads from this
    /// directory instead of the App Group container.
    var portFileDirectoryOverride: URL?

    init(pollInterval: TimeInterval = 2.0) {
        self.pollInterval = pollInterval
    }

    func startChecking() {
        // Check immediately
        isDaemonAvailable = checkPortFile()
        log.info("Daemon status check started, available: \(self.isDaemonAvailable)")

        // Poll at the configured interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
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

    func checkPortFile() -> Bool {
        let container: URL?
        if let override = portFileDirectoryOverride {
            container = override
        } else {
            container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
            )
        }
        guard let container else { return false }

        let portFile = container.appendingPathComponent("terminal-server-port")
        guard let contents = try? String(contentsOf: portFile, encoding: .utf8),
              let port = UInt16(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0 else {
            return false
        }

        // When using the test override, skip the connectivity check —
        // unit tests validate port file parsing; connectivity is tested
        // separately via UI/integration tests.
        if portFileDirectoryOverride != nil {
            return true
        }

        // Verify the daemon is actually listening on this port.
        // For localhost, connect() returns immediately: 0 if open,
        // -1 with ECONNREFUSED if nothing is listening.
        guard canConnect(toPort: port) else {
            log.info("Port file exists (\(port)) but daemon is not reachable — stale port file")
            return false
        }
        return true
    }

    private func canConnect(toPort port: UInt16) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }
}
