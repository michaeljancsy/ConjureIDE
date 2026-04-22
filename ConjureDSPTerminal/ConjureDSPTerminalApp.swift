//
//  ConjureDSPTerminalApp.swift
//  ConjureDSPTerminal
//
//  Companion app that runs Claude Code terminal sessions outside the AU
//  extension sandbox. Supports multiple simultaneous AU instances — each
//  gets its own dedicated PTY + WebSocket pair.
//
//  Discovery uses a directory of JSON files in the App Group container:
//    mcp-instances/{uuid}.json
//  Each AU writes { mcpPort, pid, createdAt }. This app watches the
//  directory, starts a session per instance, and writes wsPort back.
//

import SwiftUI
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "TerminalApp")

@main
struct ConjureDSPTerminalApp: App {
    @State private var server = TerminalAppServer()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        SentrySetup.start()
    }

    var body: some Scene {
        WindowGroup {
            TerminalStatusView(server: server)
                .frame(width: 360, height: 200)
                .onAppear {
                    server.start()
                }
                .onOpenURL { _ in
                    // URL scheme (conjuredsp-terminal://) triggers app launch.
                    // The server starts on appear — nothing extra needed here.
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 200)
    }
}

// MARK: - Instance Session

/// One PTY + WebSocket pair for a single AU instance.
@MainActor
class InstanceSession {
    let uuid: String
    let mcpPort: UInt16
    var wsServer: WebSocketServer?
    var pty: PTYManager?
    var wsPort: UInt16?
    var healthCheckFailCount: Int = 0
    var claudeState: String = "Idle"

    init(uuid: String, mcpPort: UInt16) {
        self.uuid = uuid
        self.mcpPort = mcpPort
    }
}

// MARK: - Server

@MainActor
@Observable
class TerminalAppServer {
    private(set) var status: String = "Starting..."
    private(set) var activeSessionCount: Int = 0

    private var sessions: [String: InstanceSession] = [:]
    private var watchTask: Task<Void, Never>?
    private let healthCheckThreshold = 3
    private var packageInstaller: PackageInstaller?
    private var crateInstaller: CrateInstaller?
    private var exportFinalizer: ExportFinalizer?
    private var gitWorker: GitWorker?
    private var exportNotificationObserver: NSObjectProtocol?

    /// URL of the shared Python runtime in the App Group container.
    static let pythonRuntimeURL: URL = AppGroupContainer.url.appendingPathComponent("PythonRuntime")

    func start() {
        log.info("ConjureDSP Terminal starting")
        status = "Waiting for ConjureDSP plugin..."

        // Provision shared runtimes to the App Group container.
        DispatchQueue.global(qos: .utility).async { [self] in
            Self.installPythonRuntimeIfNeeded()
            Self.provisionUVIfNeeded()
            Self.provisionRustToolchainIfNeeded()

            Task { @MainActor in
                let containerURL = AppGroupContainer.url
                self.packageInstaller = PackageInstaller(appGroupURL: containerURL)
                if self.packageInstaller != nil {
                    log.info("Package installer ready")
                } else {
                    log.error("Package installer failed to initialize — uv not available")
                }

                self.crateInstaller = CrateInstaller(appGroupURL: containerURL)
                if self.crateInstaller != nil {
                    log.info("Crate installer ready")
                } else {
                    log.warning("Crate installer not available — cargo not found in rustc-dist")
                }

                self.exportFinalizer = ExportFinalizer(
                    appGroupURL: containerURL
                )
                log.info("Export finalizer ready")

                self.gitWorker = GitWorker(appGroupURL: containerURL)
                if self.gitWorker != nil {
                    log.info("Git worker ready")
                } else {
                    log.warning("Git worker not available — no usable git binary found")
                }

                self.exportNotificationObserver = DistributedNotificationCenter.default().addObserver(
                    forName: Notification.Name("com.MichaelJancsy.ConjureDSP.pendingExport"),
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self, let finalizer = self.exportFinalizer else { return }
                    Task { @MainActor in
                        await finalizer.checkForPendingExports()
                    }
                }
            }
        }

        // Clean up stale instance files from previous runs
        cleanupStaleInstances()

        startWatching()
    }

    // MARK: - Instance directory watching

    /// Continuously scan mcp-instances/ for new, changed, or removed instance files.
    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            var tickCount = 0
            while !Task.isCancelled {
                guard let self else { return }

                self.reconcileInstances()

                // Package/crate install requests
                if let installer = self.packageInstaller {
                    await installer.checkForRequests()
                }
                if let crateInst = self.crateInstaller {
                    await crateInst.checkForRequests()
                }
                if let finalizer = self.exportFinalizer {
                    await finalizer.checkForPendingExports()
                }
                if let git = self.gitWorker {
                    await git.checkForRequests()
                }

                // Health checks every ~3 seconds
                if tickCount % 6 == 0 {
                    await self.healthCheckAllSessions()
                }

                tickCount += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Compare current instance files against running sessions.
    /// Start new sessions, tear down removed ones.
    private func reconcileInstances() {
        let instancesDir = instancesDirectoryURL()
        let fm = FileManager.default

        // Ensure directory exists
        try? fm.createDirectory(at: instancesDir, withIntermediateDirectories: true)

        // Read all current instance files
        let files = (try? fm.contentsOfDirectory(at: instancesDir, includingPropertiesForKeys: nil)) ?? []
        var currentUUIDs = Set<String>()

        for file in files {
            guard file.pathExtension == "json" else { continue }
            let uuid = file.deletingPathExtension().lastPathComponent
            currentUUIDs.insert(uuid)

            guard let info = MCPInstanceInfo.read(from: file) else { continue }

            if let session = sessions[uuid] {
                // Session exists — check if MCP port changed
                if session.mcpPort != info.mcpPort {
                    log.info("MCP port changed for \(uuid, privacy: .public): \(session.mcpPort) → \(info.mcpPort) — restarting")
                    teardownSession(uuid: uuid)
                    startSession(uuid: uuid, mcpPort: info.mcpPort)
                }
            } else {
                // New instance — start a session
                log.info("New instance detected: \(uuid, privacy: .public) on MCP port \(info.mcpPort)")
                startSession(uuid: uuid, mcpPort: info.mcpPort)
            }
        }

        // Tear down sessions whose instance files are gone
        for uuid in sessions.keys where !currentUUIDs.contains(uuid) {
            log.info("Instance \(uuid, privacy: .public) deregistered — tearing down session")
            teardownSession(uuid: uuid)
        }

        // Update status
        activeSessionCount = sessions.count
        if sessions.isEmpty {
            status = "Waiting for ConjureDSP plugin..."
        } else if sessions.count == 1 {
            let s = sessions.values.first!
            status = "Ready (MCP: \(s.mcpPort), WS: \(s.wsPort ?? 0))"
        } else {
            status = "\(sessions.count) sessions active"
        }
    }

    // MARK: - Session lifecycle

    private func startSession(uuid: String, mcpPort: UInt16) {
        let session = InstanceSession(uuid: uuid, mcpPort: mcpPort)

        let ws = WebSocketServer()
        let p = PTYManager()
        session.wsServer = ws
        session.pty = p

        // Start WebSocket server on a dynamic port
        ws.onReady = { [weak self, weak session] confirmedPort in
            guard let self, let session else { return }
            session.wsPort = confirmedPort
            self.writeWSPort(confirmedPort, forInstance: uuid)
            Task { @MainActor [weak self] in
                self?.updateStatus()
            }
        }
        ws.start(port: 0)

        // Configure PTY
        p.mcpServerPort = mcpPort

        p.onOutput = { [weak ws] data in
            ws?.broadcast(data)
        }

        p.onDisplayText = { [weak ws] text in
            // If no clients are connected yet, queue the banner for the first connection.
            if let ws, ws.clientCount > 0 {
                ws.broadcastText(text)
            } else {
                ws?.pendingBanner = text
            }
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

        p.onStateChange = { [weak self, weak session] state in
            Task { @MainActor in
                guard let session else { return }
                switch state {
                case .running:
                    session.claudeState = "Running"
                    session.wsServer?.broadcastText("\u{1b}[32m● Terminal ready\u{1b}[0m\r\n")
                case .exited(let code):
                    session.claudeState = "Exited (code \(code))"
                    session.wsServer?.broadcastText("\r\n\u{1b}[33m● Terminal session ended (code \(code)).\u{1b}[0m\r\n")
                case .error(let msg):
                    session.claudeState = "Error: \(msg)"
                    session.wsServer?.broadcastText("\r\n\u{1b}[31m● Error: \(msg)\u{1b}[0m\r\n")
                case .idle:
                    session.claudeState = "Idle"
                }
                self?.updateStatus()
            }
        }

        ws.onClientCountChange = { [weak p] count in
            guard let p else { return }
            if count > 0 {
                switch p.state {
                case .idle, .exited(_):
                    p.start()
                case .running:
                    p.sendSIGWINCH()
                case .error:
                    break
                }
            }
        }

        sessions[uuid] = session
        activeSessionCount = sessions.count
        log.info("Session started for \(uuid, privacy: .public) — MCP: \(mcpPort)")
    }

    private func teardownSession(uuid: String) {
        guard let session = sessions.removeValue(forKey: uuid) else { return }
        session.pty?.stop()
        session.wsServer?.stop()
        activeSessionCount = sessions.count
        log.info("Session torn down for \(uuid, privacy: .public)")
    }

    private func updateStatus() {
        if sessions.isEmpty {
            status = "Waiting for ConjureDSP plugin..."
        } else if sessions.count == 1 {
            let s = sessions.values.first!
            status = "Ready (MCP: \(s.mcpPort), WS: \(s.wsPort ?? 0))"
        } else {
            status = "\(sessions.count) sessions active"
        }
    }

    // MARK: - Health checks

    private func healthCheckAllSessions() async {
        // Snapshot the keys to avoid mutating `sessions` during iteration.
        var uuidsToTearDown: [String] = []
        for (uuid, session) in sessions {
            let healthy = await checkMCPHealth(port: session.mcpPort)
            if healthy {
                session.healthCheckFailCount = 0
            } else {
                session.healthCheckFailCount += 1
                if session.healthCheckFailCount >= healthCheckThreshold {
                    log.info("MCP server for \(uuid, privacy: .public) unreachable after \(session.healthCheckFailCount) checks — scheduling teardown")
                    uuidsToTearDown.append(uuid)
                }
            }
        }
        for uuid in uuidsToTearDown {
            teardownSession(uuid: uuid)
            let file = instancesDirectoryURL().appendingPathComponent("\(uuid).json")
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func checkMCPHealth(port: UInt16) async -> Bool {
        guard port > 0,
              let url = URL(string: "http://localhost:\(port)/health") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String, status == "ok" {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Stale cleanup

    /// Remove instance files from crashed AUs (pid no longer alive).
    private func cleanupStaleInstances() {
        let instancesDir = instancesDirectoryURL()
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(at: instancesDir, includingPropertiesForKeys: nil) else { return }

        for file in files {
            guard file.pathExtension == "json" else { continue }
            guard let info = MCPInstanceInfo.read(from: file) else {
                try? fm.removeItem(at: file)
                continue
            }

            // Check if the process is still alive
            if let pid = info.pid, pid > 0 {
                let alive = kill(pid, 0) == 0
                if !alive {
                    let uuid = file.deletingPathExtension().lastPathComponent
                    log.info("Removing stale instance file for \(uuid, privacy: .public) (pid \(pid) dead)")
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    // MARK: - Container helpers

    private func containerURL() -> URL {
        AppGroupContainer.url
    }

    private func instancesDirectoryURL() -> URL {
        containerURL().appendingPathComponent("mcp-instances")
    }

    /// Write the WebSocket port back to the instance's JSON file.
    private func writeWSPort(_ wsPort: UInt16, forInstance uuid: String) {
        let file = instancesDirectoryURL().appendingPathComponent("\(uuid).json")
        guard var info = MCPInstanceInfo.read(from: file) else {
            log.warning("Instance file gone for \(uuid, privacy: .public) when writing wsPort")
            return
        }
        info.wsPort = wsPort
        do {
            try info.write(to: file)
        } catch {
            log.error("Failed to write wsPort for \(uuid, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Python/UV/Rust provisioning

    nonisolated static func installPythonRuntimeIfNeeded() {
        let runtimeURL = pythonRuntimeURL

        guard let bundledPythonDist = Bundle.main.resourceURL?.appendingPathComponent("python-dist"),
              FileManager.default.fileExists(atPath: bundledPythonDist.path) else {
            log.error("Bundled python-dist not found in Terminal app bundle")
            SentryHelper.capture("Bundled python-dist not found", level: .error, category: "terminal.python")
            return
        }

        if isProvisionedCurrent(at: runtimeURL) {
            log.info("Shared Python runtime already installed and current at \(runtimeURL.path, privacy: .public)")
        } else {
            do {
                let fm = FileManager.default

                let srcBin = bundledPythonDist.appendingPathComponent("bin/python3")
                let dstBin = runtimeURL.appendingPathComponent("bin")
                try fm.createDirectory(at: dstBin, withIntermediateDirectories: true)
                let dstPython = dstBin.appendingPathComponent("python3")
                if fm.fileExists(atPath: dstPython.path) {
                    try fm.removeItem(at: dstPython)
                }
                try fm.copyItem(at: srcBin, to: dstPython)

                let srcDylib = bundledPythonDist.appendingPathComponent("lib/libpython3.14t.dylib")
                let dstLib = runtimeURL.appendingPathComponent("lib")
                try fm.createDirectory(at: dstLib, withIntermediateDirectories: true)
                let dstDylib = dstLib.appendingPathComponent("libpython3.14t.dylib")
                if fm.fileExists(atPath: dstDylib.path) {
                    try fm.removeItem(at: dstDylib)
                }
                try fm.copyItem(at: srcDylib, to: dstDylib)

                let srcStdlib = bundledPythonDist.appendingPathComponent("lib/python3.14t")
                let dstStdlib = dstLib.appendingPathComponent("python3.14t")
                if fm.fileExists(atPath: dstStdlib.path) {
                    try fm.removeItem(at: dstStdlib)
                }
                try fm.copyItem(at: srcStdlib, to: dstStdlib)

                writeVersionMarker(at: runtimeURL)
                log.info("Shared Python runtime installed at \(runtimeURL.path, privacy: .public)")
                migrateUserPackages(to: dstStdlib.appendingPathComponent("site-packages"))
            } catch {
                log.error("Failed to install shared Python runtime: \(error.localizedDescription, privacy: .public)")
                SentryHelper.captureError(error, category: "terminal.python")
            }
        }

        updateConjureDSPPackage(bundledPythonDist: bundledPythonDist, runtimeURL: runtimeURL)
    }

    nonisolated private static func updateConjureDSPPackage(bundledPythonDist: URL, runtimeURL: URL) {
        let fm = FileManager.default
        let srcConjuredsp = bundledPythonDist
            .appendingPathComponent("lib/python3.14t/site-packages/conjuredsp")

        guard fm.fileExists(atPath: srcConjuredsp.path) else {
            log.warning("Bundled conjuredsp package not found at \(srcConjuredsp.path, privacy: .public)")
            return
        }

        let dstConjuredsp = runtimeURL
            .appendingPathComponent("lib/python3.14t/site-packages/conjuredsp")
        do {
            if fm.fileExists(atPath: dstConjuredsp.path) {
                try fm.removeItem(at: dstConjuredsp)
            }
            try fm.copyItem(at: srcConjuredsp, to: dstConjuredsp)
            log.info("Updated conjuredsp package in site-packages")
        } catch {
            log.error("Failed to update conjuredsp package: \(error.localizedDescription, privacy: .public)")
            SentryHelper.captureError(error, category: "terminal.python")
        }
    }

    nonisolated private static func migrateUserPackages(to sitePackages: URL) {
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

    nonisolated static func findRustcDist() -> URL? {
        let extensionRustcDist = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PlugIns/ConjureDSPExtension.appex/Contents/Resources/rustc-dist")
        if FileManager.default.fileExists(atPath: extensionRustcDist.path) {
            return extensionRustcDist
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("rustc-dist"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    /// The current app build number, used to detect when provisioned tools need updating.
    private nonisolated static var appBuildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Check whether a provisioned directory is current by comparing a `.version` marker
    /// against the app's build number. Returns true if already up-to-date.
    private nonisolated static func isProvisionedCurrent(at directory: URL) -> Bool {
        let versionFile = directory.appendingPathComponent(".version")
        guard let stored = try? String(contentsOf: versionFile, encoding: .utf8) else { return false }
        return stored.trimmingCharacters(in: .whitespacesAndNewlines) == appBuildVersion
    }

    /// Write the current app build version into a `.version` marker file.
    private nonisolated static func writeVersionMarker(at directory: URL) {
        let versionFile = directory.appendingPathComponent(".version")
        try? appBuildVersion.write(to: versionFile, atomically: true, encoding: .utf8)
    }

    nonisolated static func provisionRustToolchainIfNeeded() {
        let containerURL = AppGroupContainer.url
        let dstRustcDist = containerURL.appendingPathComponent("rustc-dist")

        if isProvisionedCurrent(at: dstRustcDist) {
            log.info("Rust toolchain already provisioned and current at \(dstRustcDist.path, privacy: .public)")
            return
        }

        guard let rustcDistSource = findRustcDist() else {
            log.warning("rustc-dist not found — crate management unavailable")
            return
        }

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dstRustcDist.path) {
                try fm.removeItem(at: dstRustcDist)
            }
            try fm.copyItem(at: rustcDistSource, to: dstRustcDist)
            writeVersionMarker(at: dstRustcDist)
            log.info("Rust toolchain provisioned to App Group at \(dstRustcDist.path, privacy: .public)")
        } catch {
            log.error("Failed to provision Rust toolchain: \(error.localizedDescription, privacy: .public)")
            SentryHelper.captureError(error, category: "terminal.rust")
        }
    }

    nonisolated static func provisionUVIfNeeded() {
        let containerURL = AppGroupContainer.url
        let dstUV = containerURL.appendingPathComponent("uv")
        let versionFile = containerURL.appendingPathComponent(".uv-version")

        if let stored = try? String(contentsOf: versionFile, encoding: .utf8),
           stored.trimmingCharacters(in: .whitespacesAndNewlines) == appBuildVersion {
            log.info("uv already provisioned and current in App Group at \(dstUV.path, privacy: .public)")
            return
        }

        guard let bundledUV = Bundle.main.resourceURL?.appendingPathComponent("uv"),
              FileManager.default.fileExists(atPath: bundledUV.path) else {
            log.warning("Bundled uv not found in Terminal app bundle — package management requires rebuild")
            return
        }

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dstUV.path) {
                try fm.removeItem(at: dstUV)
            }
            try fm.copyItem(at: bundledUV, to: dstUV)
            try appBuildVersion.write(to: versionFile, atomically: true, encoding: .utf8)
            log.info("uv provisioned to App Group at \(dstUV.path, privacy: .public)")
        } catch {
            log.error("Failed to provision uv to App Group: \(error.localizedDescription, privacy: .public)")
            SentryHelper.captureError(error, category: "terminal.uv")
        }
    }
}

// MARK: - UI

struct TerminalStatusView: View {
    let server: TerminalAppServer

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(server.activeSessionCount > 0 ? .green : .secondary)

            Text("ConjureDSP Terminal")
                .font(.headline)

            Text(server.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
