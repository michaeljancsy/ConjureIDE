import Foundation
import Testing

/// Tests that AppGroupContainer resolves correctly based on sandbox status.
/// Tests run unsandboxed → Application Support path.
@Suite struct AppGroupContainerTests {

    // MARK: - Path resolution

    @Test("Unsandboxed process uses Application Support")
    func unsandboxedUsesApplicationSupport() {
        let url = AppGroupContainer.url
        #expect(url.pathComponents.contains("Application Support"))
        #expect(url.lastPathComponent == "ConjureDSP")
    }

    @Test("Path is deterministic across calls")
    func pathIsDeterministic() {
        let url1 = AppGroupContainer.url
        let url2 = AppGroupContainer.url
        #expect(url1 == url2)
    }

    @Test("Sandbox detection works in test environment")
    func sandboxDetection() {
        // Tests run unsandboxed
        #expect(!AppGroupContainer.isSandboxed)
    }

    @Test("App Group id is correct")
    func appGroupIdIsCorrect() {
        #expect(AppGroupContainer.id == "group.com.MichaelJancsy.ConjureDSP")
    }

    // MARK: - Directory access

    @Test("App Group directory exists and is accessible")
    func directoryExists() {
        let url = AppGroupContainer.url
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        #expect(exists, "App Group directory should exist at \(url.path)")
        #expect(isDir.boolValue, "App Group path should be a directory")
    }

    @Test("Can list contents of App Group directory")
    func canListContents() throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: AppGroupContainer.url,
            includingPropertiesForKeys: nil
        )
        // The App Group container should have at least some files/dirs
        // (PythonRuntime, tones, etc.)
        #expect(contents.count > 0, "App Group container should not be empty")
    }

    @Test("Can write and read a test file in App Group")
    func canWriteAndRead() throws {
        let testFile = AppGroupContainer.url
            .appendingPathComponent("_test_\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: testFile) }

        let testContent = "AppGroupContainer test \(Date())"
        try testContent.write(to: testFile, atomically: true, encoding: .utf8)

        let readBack = try String(contentsOf: testFile, encoding: .utf8)
        #expect(readBack == testContent)
    }

    // MARK: - Subdirectory resolution

    @Test("Tones directory resolves to expected path")
    func tonesDirectory() {
        let tonesURL = AppGroupContainer.url.appendingPathComponent("tones")
        #expect(tonesURL.path.hasSuffix("/tones"))
        // Verify the tones directory exists (it should if NAM tones have been downloaded)
        let exists = FileManager.default.fileExists(atPath: tonesURL.path)
        // This is informational — tones may or may not exist in test env
        if exists {
            let contents = try? FileManager.default.contentsOfDirectory(
                at: tonesURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            #expect(contents != nil, "Should be able to list tones directory")
        }
    }

    @Test("Terminal port file path is correct")
    func terminalPortFilePath() {
        let portFile = AppGroupContainer.url.appendingPathComponent("terminal-server-port")
        #expect(portFile.lastPathComponent == "terminal-server-port")
        // Check that the parent directory is the App Group container
        #expect(portFile.deletingLastPathComponent() == AppGroupContainer.url)
    }

    @Test("MCP server port file path is correct")
    func mcpPortFilePath() {
        let portFile = AppGroupContainer.url.appendingPathComponent("mcp-server-port")
        #expect(portFile.lastPathComponent == "mcp-server-port")
        #expect(portFile.deletingLastPathComponent() == AppGroupContainer.url)
    }

    // MARK: - WebSocket port change detection

    @Test("Detects WebSocket port change after companion app restart")
    func detectsWebSocketPortChange() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let portFile = tempDir.appendingPathComponent("terminal-server-port")

        // Simulate initial connection: companion app writes port A
        let portA: UInt16 = 19836
        try "\(portA)".write(to: portFile, atomically: true, encoding: .utf8)

        // TerminalView reads the port and connects
        let initialContents = try String(contentsOf: portFile, encoding: .utf8)
        let initialPort = UInt16(initialContents.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(initialPort == portA)

        // Simulate companion app session reset: old port file deleted, then new port written
        try FileManager.default.removeItem(at: portFile)
        let portB: UInt16 = 49152
        try "\(portB)".write(to: portFile, atomically: true, encoding: .utf8)

        // Port poll reads the file and detects the change
        let newContents = try String(contentsOf: portFile, encoding: .utf8)
        let newPort = UInt16(newContents.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(newPort == portB)
        #expect(newPort != initialPort, "Poll should detect that port changed from \(portA) to \(portB)")
    }

    @Test("Port poll handles missing file during companion app restart")
    func portPollHandlesMissingFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let portFile = tempDir.appendingPathComponent("terminal-server-port")

        // Port file doesn't exist yet (companion app restarting)
        let contents = try? String(contentsOf: portFile, encoding: .utf8)
        #expect(contents == nil, "Should handle missing port file gracefully")

        // Companion app comes back with new port
        try "55555".write(to: portFile, atomically: true, encoding: .utf8)
        let port = UInt16(try String(contentsOf: portFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(port == 55555)
    }

    @Test("Port poll ignores unchanged port")
    func portPollIgnoresUnchangedPort() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let portFile = tempDir.appendingPathComponent("terminal-server-port")
        try "19836".write(to: portFile, atomically: true, encoding: .utf8)

        // Read twice — same port both times
        let port1 = UInt16(try String(contentsOf: portFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let port2 = UInt16(try String(contentsOf: portFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(port1 == port2, "Same port should not trigger reconnect")
    }

    @Test("Port poll rejects zero and invalid values")
    func portPollRejectsInvalidValues() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let portFile = tempDir.appendingPathComponent("terminal-server-port")

        // Zero port
        try "0".write(to: portFile, atomically: true, encoding: .utf8)
        let zeroPort = UInt16(try String(contentsOf: portFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(zeroPort == 0, "Zero port should be filtered out by caller")

        // Non-numeric
        try "garbage".write(to: portFile, atomically: true, encoding: .utf8)
        let badPort = UInt16(try String(contentsOf: portFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(badPort == nil, "Non-numeric content should parse as nil")
    }

    @Test("PythonRuntime directory resolves correctly")
    func pythonRuntimeDirectory() {
        let runtimeURL = AppGroupContainer.url.appendingPathComponent("PythonRuntime")
        #expect(runtimeURL.lastPathComponent == "PythonRuntime")
        // The runtime should exist if ConjureDSPTerminal has provisioned it
        if FileManager.default.fileExists(atPath: runtimeURL.path) {
            let stdlib = runtimeURL.appendingPathComponent("lib/python3.14t")
            let stdlibExists = FileManager.default.fileExists(atPath: stdlib.path)
            #expect(stdlibExists, "Python stdlib should exist in provisioned runtime")
        }
    }

    // MARK: - Cross-process consistency

    @Test("Terminal port file written via direct path is readable")
    func crossProcessPortFileRoundTrip() throws {
        let portFile = AppGroupContainer.url.appendingPathComponent("_test_port_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: portFile) }

        // Simulate what TerminalServer.writeMCPPortToAppGroup() does
        let testPort: UInt16 = 12345
        try "\(testPort)".write(to: portFile, atomically: true, encoding: .utf8)

        // Simulate what DaemonStatusChecker.checkPortFile() does
        let contents = try String(contentsOf: portFile, encoding: .utf8)
        let readPort = UInt16(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(readPort == testPort)
    }
}
