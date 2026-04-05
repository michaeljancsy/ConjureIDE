import Foundation
import Testing

/// Tests that the direct-path AppGroupContainer resolves correctly and
/// matches the system API, verifying the TCC-prompt-free migration.
@Suite struct AppGroupContainerTests {

    // MARK: - Path resolution

    @Test("Direct path matches containerURL API")
    func directPathMatchesAPI() throws {
        // The system API that we're avoiding (triggers TCC prompt on macOS 26)
        let apiURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupContainer.id
        )
        // Skip if App Group not available (CI without entitlements)
        try #require(apiURL != nil, "App Group container not available via API")

        // Our direct path construction (the replacement)
        let directURL = AppGroupContainer.url

        // Standardize both to strip any trailing slashes or symlinks
        #expect(
            directURL.standardizedFileURL == apiURL!.standardizedFileURL,
            "Direct path \(directURL.path) must match API path \(apiURL!.path)"
        )
    }

    @Test("Direct path is deterministic across calls")
    func directPathIsDeterministic() {
        let url1 = AppGroupContainer.url
        let url2 = AppGroupContainer.url
        #expect(url1 == url2)
    }

    @Test("Path contains expected components")
    func pathContainsExpectedComponents() {
        let url = AppGroupContainer.url
        #expect(url.pathComponents.contains("Library"))
        #expect(url.pathComponents.contains("Group Containers"))
        #expect(url.lastPathComponent == "group.com.MichaelJancsy.ConjureDSP")
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
