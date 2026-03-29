//
//  ConjureDSPTerminalApp.swift
//  ConjureDSPTerminal
//
//  Minimal companion app that runs the Claude Code terminal outside the
//  AU extension sandbox. The AU extension communicates with this app via
//  the App Group container for port discovery and lifecycle signaling.
//

import SwiftUI
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "TerminalApp")

@main
struct ConjureDSPTerminalApp: App {
    @State private var server = TerminalAppServer()

    var body: some Scene {
        WindowGroup {
            TerminalStatusView(server: server)
                .frame(width: 360, height: 200)
                .onAppear {
                    server.start()
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 200)
    }
}

// MARK: - Server

@MainActor
@Observable
class TerminalAppServer {
    private(set) var status: String = "Starting..."
    private(set) var isRunning = false
    private(set) var claudeState: String = "Idle"

    private var wsServer: WebSocketServer?
    private var pty: PTYManager?
    private var watchTask: Task<Void, Never>?
    private var currentMCPPort: UInt16 = 0
    private var healthCheckFailCount = 0
    private let healthCheckThreshold = 3  // consecutive failures before reset
    private var packageInstaller: PackageInstaller?

    private let appGroupID = "group.com.MichaelJancsy.ConjureDSP"

    /// URL of the shared Python runtime in the App Group container.
    /// This is the single authoritative Python installation used by the AU extension,
    /// package manager, and exported AUs.
    static let pythonRuntimeURL: URL? = {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.MichaelJancsy.ConjureDSP"
        )?.appendingPathComponent("PythonRuntime")
    }()

    func start() {
        log.info("ConjureDSP Terminal starting")
        status = "Waiting for ConjureDSP plugin..."

        // Initialize package installer if App Group is available
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            packageInstaller = PackageInstaller(appGroupURL: containerURL)
            if packageInstaller != nil {
                log.info("Package installer ready")
            }
        }

        // Provision the shared Python runtime to the App Group container
        DispatchQueue.global(qos: .utility).async {
            Self.installPythonRuntimeIfNeeded()
        }

        startWatching()
    }

    /// Copies the bundled Python distribution to the App Group container so the AU
    /// extension and package manager can use it. No-op if already installed.
    static func installPythonRuntimeIfNeeded() {
        guard let runtimeURL = pythonRuntimeURL else {
            log.error("App Group container not available — cannot install Python runtime")
            return
        }

        let stdlibPath = runtimeURL.appendingPathComponent("lib/python3.14t").path
        if FileManager.default.fileExists(atPath: stdlibPath) {
            log.info("Shared Python runtime already installed at \(runtimeURL.path, privacy: .public)")
            return
        }

        guard let bundledPythonDist = Bundle.main.resourceURL?.appendingPathComponent("python-dist"),
              FileManager.default.fileExists(atPath: bundledPythonDist.path) else {
            log.error("Bundled python-dist not found in Terminal app bundle")
            return
        }

        do {
            let fm = FileManager.default

            // Copy bin/python3
            let srcBin = bundledPythonDist.appendingPathComponent("bin/python3")
            let dstBin = runtimeURL.appendingPathComponent("bin")
            try fm.createDirectory(at: dstBin, withIntermediateDirectories: true)
            let dstPython = dstBin.appendingPathComponent("python3")
            if fm.fileExists(atPath: dstPython.path) {
                try fm.removeItem(at: dstPython)
            }
            try fm.copyItem(at: srcBin, to: dstPython)

            // Copy lib/libpython3.14t.dylib
            let srcDylib = bundledPythonDist.appendingPathComponent("lib/libpython3.14t.dylib")
            let dstLib = runtimeURL.appendingPathComponent("lib")
            try fm.createDirectory(at: dstLib, withIntermediateDirectories: true)
            let dstDylib = dstLib.appendingPathComponent("libpython3.14t.dylib")
            if fm.fileExists(atPath: dstDylib.path) {
                try fm.removeItem(at: dstDylib)
            }
            try fm.copyItem(at: srcDylib, to: dstDylib)

            // Copy lib/python3.14t/ (stdlib + numpy + scipy)
            let srcStdlib = bundledPythonDist.appendingPathComponent("lib/python3.14t")
            let dstStdlib = dstLib.appendingPathComponent("python3.14t")
            if fm.fileExists(atPath: dstStdlib.path) {
                try fm.removeItem(at: dstStdlib)
            }
            try fm.copyItem(at: srcStdlib, to: dstStdlib)

            log.info("Shared Python runtime installed at \(runtimeURL.path, privacy: .public)")

            // Migrate existing user-packages if present
            migrateUserPackages(to: dstStdlib.appendingPathComponent("site-packages"))
        } catch {
            log.error("Failed to install shared Python runtime: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One-time migration: move packages from the old user-packages directory into site-packages.
    private static func migrateUserPackages(to sitePackages: URL) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldUserPackages = appSupport.appendingPathComponent("ConjureDSP/user-packages")
        let fm = FileManager.default

        guard fm.fileExists(atPath: oldUserPackages.path),
              let contents = try? fm.contentsOfDirectory(at: oldUserPackages, includingPropertiesForKeys: nil),
              !contents.isEmpty else { return }

        log.info("Migrating user-packages to shared runtime site-packages")
        for item in contents {
            let dest = sitePackages.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: item, to: dest)
            }
        }
        log.info("Migration complete — old user-packages preserved at \(oldUserPackages.path, privacy: .public)")
    }

    // MARK: - App Group file watching

    /// Continuously watch for lifecycle changes via three mechanisms:
    /// 1. Shutdown signal — clean AU teardown (deinit wrote the file)
    /// 2. Port change — AU restarted, new MCP server on a different port
    /// 3. Health check — MCP server stopped responding (AU crashed or closed without signal)
    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            var tickCount = 0
            while !Task.isCancelled {
                guard let self else { return }

                // 1. Shutdown signal (fastest detection — file written by AU deinit)
                if self.isRunning, self.shutdownSignalExists() {
                    log.info("Shutdown signal detected — resetting")
                    self.resetSession()
                    self.deleteAppGroupFile("terminal-shutdown")
                    self.status = "Waiting for ConjureDSP plugin..."
                }

                // 2. Port change or new port
                if let port = self.readMCPPort() {
                    if !self.isRunning {
                        log.info("MCP port detected: \(port) — starting session")
                        self.startSession(mcpPort: port)
                    } else if port != self.currentMCPPort {
                        log.info("MCP port changed \(self.currentMCPPort) → \(port) — restarting session")
                        self.resetSession()
                        self.startSession(mcpPort: port)
                    }
                }

                // 3. Check for package install/uninstall requests
                if let installer = self.packageInstaller {
                    await installer.checkForRequests()
                }

                // 4. Health check (every ~3 seconds when running)
                if self.isRunning, tickCount % 6 == 0 {
                    let healthy = await self.checkMCPHealth()
                    if healthy {
                        self.healthCheckFailCount = 0
                    } else {
                        self.healthCheckFailCount += 1
                        if self.healthCheckFailCount >= self.healthCheckThreshold {
                            log.info("MCP server unreachable after \(self.healthCheckFailCount) checks — resetting")
                            self.resetSession()
                            self.deleteAppGroupFile("mcp-server-port")
                            self.status = "Waiting for ConjureDSP plugin..."
                        }
                    }
                }

                tickCount += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Ping the MCP server's health endpoint.
    private func checkMCPHealth() async -> Bool {
        guard currentMCPPort > 0,
              let url = URL(string: "http://localhost:\(currentMCPPort)/health") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            // Verify it's actually our server
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String, status == "ok" {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Session lifecycle

    private func startSession(mcpPort: UInt16) {
        let ws = WebSocketServer()
        let p = PTYManager()
        self.wsServer = ws
        self.pty = p

        // Start WebSocket server — write port file only after listener confirms ready
        let wsPort: UInt16 = 19836
        ws.onReady = { [weak self] confirmedPort in
            self?.writeWebSocketPort(confirmedPort)
        }
        ws.start(port: wsPort)

        // Configure PTY
        p.mcpServerPort = mcpPort

        p.onOutput = { [weak ws] data in
            ws?.broadcast(data)
        }

        ws.onClientInput = { [weak p] data in
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String, type == "resize",
               let cols = json["cols"] as? Int, let rows = json["rows"] as? Int {
                p?.resize(cols: UInt16(cols), rows: UInt16(rows))
            } else {
                p?.write(data)
            }
        }

        p.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .running:
                    self.claudeState = "Running"
                    self.wsServer?.broadcastText("\u{1b}[32m● Terminal ready\u{1b}[0m\r\n")
                case .exited(let code):
                    self.claudeState = "Exited (code \(code))"
                    self.wsServer?.broadcastText("\r\n\u{1b}[33m● Terminal session ended (code \(code)).\u{1b}[0m\r\n")
                case .error(let msg):
                    self.claudeState = "Error: \(msg)"
                    self.wsServer?.broadcastText("\r\n\u{1b}[31m● Error: \(msg)\u{1b}[0m\r\n")
                case .idle:
                    self.claudeState = "Idle"
                }
            }
        }

        ws.onClientCountChange = { [weak p] count in
            guard let p else { return }
            if count > 0 {
                switch p.state {
                case .idle, .exited(_):
                    p.start()
                case .running:
                    // New client connected to an already-running PTY — send SIGWINCH
                    // to redraw the screen for the fresh xterm.js
                    p.sendSIGWINCH()
                case .error:
                    break
                }
            }
        }

        currentMCPPort = mcpPort
        isRunning = true
        status = "Ready (MCP: \(mcpPort), WS: \(wsPort))"
        log.info("Session started — MCP: \(mcpPort), WS: \(wsPort)")
    }

    private func resetSession() {
        // Stop PTY (kills Claude Code)
        pty?.stop()
        pty = nil

        // Stop WebSocket server
        wsServer?.stop()
        wsServer = nil

        currentMCPPort = 0
        healthCheckFailCount = 0
        isRunning = false
        claudeState = "Idle"
        log.info("Session reset")
    }

    // MARK: - App Group helpers

    private func appGroupURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private func readMCPPort() -> UInt16? {
        guard let url = appGroupURL() else { return nil }
        let portFile = url.appendingPathComponent("mcp-server-port")
        guard let s = try? String(contentsOf: portFile, encoding: .utf8),
              let port = UInt16(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0 else { return nil }
        return port
    }

    private func shutdownSignalExists() -> Bool {
        guard let url = appGroupURL() else { return false }
        let file = url.appendingPathComponent("terminal-shutdown")
        return FileManager.default.fileExists(atPath: file.path)
    }

    private func writeWebSocketPort(_ port: UInt16) {
        guard let url = appGroupURL() else { return }
        let portFile = url.appendingPathComponent("terminal-server-port")
        try? "\(port)".write(to: portFile, atomically: true, encoding: .utf8)
    }

    private func deleteAppGroupFile(_ name: String) {
        guard let url = appGroupURL() else { return }
        let file = url.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: - UI

struct TerminalStatusView: View {
    let server: TerminalAppServer

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(server.isRunning ? .green : .secondary)

            Text("ConjureDSP Terminal")
                .font(.headline)

            Text(server.status)
                .font(.caption)
                .foregroundStyle(.secondary)

            if server.isRunning {
                HStack(spacing: 4) {
                    Circle()
                        .fill(server.claudeState == "Running" ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Text("Terminal: \(server.claudeState)")
                        .font(.caption)
                }
            }
        }
        .padding(24)
    }
}
