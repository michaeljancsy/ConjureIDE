//
//  DaemonStatusChecker.swift
//  ConjureDSPExtension
//
//  Polls the App Group container for this instance's mcp-instances/{id}.json
//  file to determine whether the ConjureDSP Terminal daemon has started a
//  dedicated PTY+WebSocket pair for this AU instance.
//

import AppKit
import Combine
import Darwin
import Foundation
import os

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.ConjureDSPExtension", category: "DaemonStatusChecker")

@MainActor
final class DaemonStatusChecker: ObservableObject {
    @Published private(set) var isDaemonAvailable: Bool = false

    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var hasAttemptedLaunch = false

    /// The AU instance ID — set via startChecking().
    private var instanceID: String?

    /// The App Group container URL — set via startChecking().
    private var appGroupContainerURL: URL?

    /// Override for testing — when non-nil, `checkInstanceFile()` reads from this
    /// directory instead of the App Group container.
    var instanceDirectoryOverride: URL?

    init(pollInterval: TimeInterval = 2.0) {
        self.pollInterval = pollInterval
    }

    func startChecking(instanceID: String, appGroupContainerURL: URL?) {
        self.instanceID = instanceID
        self.appGroupContainerURL = appGroupContainerURL

        // Check immediately
        isDaemonAvailable = checkInstanceFile()
        log.info("Daemon status check started for instance \(instanceID, privacy: .public), available: \(self.isDaemonAvailable)")

        // If not available, try to auto-launch the terminal
        if !isDaemonAvailable {
            attemptAutoLaunch()
        }

        // Poll at the configured interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let available = self.checkInstanceFile()
                if available != self.isDaemonAvailable {
                    log.info("Daemon availability changed for instance \(self.instanceID ?? "?", privacy: .public): \(available)")
                    self.isDaemonAvailable = available
                }
            }
        }
    }

    /// Attempt to launch the terminal app by its bundle path.
    /// Uses `openApplication(at:)` to avoid Apple Events TCC prompts that
    /// `NSWorkspace.shared.open(url:)` with a custom URL scheme triggers.
    /// Only tries once per checker lifetime to avoid spamming.
    func attemptAutoLaunch() {
        guard !hasAttemptedLaunch, instanceDirectoryOverride == nil else { return }
        hasAttemptedLaunch = true

        // The terminal is embedded at ConjureDSP.app/Contents/Library/ConjureDSPTerminal.app.
        // From the extension at ConjureDSP.app/Contents/PlugIns/ConjureDSPExtension.appex:
        let terminalURL = Bundle.main.bundleURL            // .appex
            .deletingLastPathComponent()                   // Contents/PlugIns/
            .deletingLastPathComponent()                   // Contents/
            .appendingPathComponent("Library/ConjureDSPTerminal.app")

        guard FileManager.default.fileExists(atPath: terminalURL.path) else {
            log.warning("Terminal app not found at \(terminalURL.path, privacy: .public)")
            return
        }

        log.info("Attempting to auto-launch terminal at \(terminalURL.path, privacy: .public)")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: terminalURL, configuration: config) { _, error in
            if let error {
                log.error("Failed to launch terminal: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stopChecking() {
        timer?.invalidate()
        timer = nil
    }

    /// Check if the terminal app has written a wsPort for this instance.
    func checkInstanceFile() -> Bool {
        guard let instanceID else { return false }

        let container: URL
        if let override = instanceDirectoryOverride {
            container = override
        } else if let url = appGroupContainerURL {
            container = url.appendingPathComponent("mcp-instances")
        } else {
            return false
        }

        let instanceFile = container.appendingPathComponent("\(instanceID).json")
        guard let info = MCPInstanceInfo.read(from: instanceFile),
              let wsPort = info.wsPort, wsPort > 0 else {
            return false
        }

        // When using the test override, skip the connectivity check
        if instanceDirectoryOverride != nil {
            return true
        }

        // Verify the daemon is actually listening on the WebSocket port
        guard canConnect(toPort: wsPort) else {
            log.info("Instance file has wsPort \(wsPort) but daemon is not reachable — stale")
            return false
        }
        return true
    }

    private func canConnect(toPort port: UInt16) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        // Set a 2-second send/connect timeout to avoid blocking the main
        // thread if something is wrong with the port.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

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
