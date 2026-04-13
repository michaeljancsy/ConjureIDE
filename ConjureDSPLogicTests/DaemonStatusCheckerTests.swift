//
//  DaemonStatusCheckerTests.swift
//  ConjureDSPTests
//
//  Unit tests for DaemonStatusChecker — validates instance file detection
//  logic and polling behavior for the terminal daemon launch prompt.
//

import Testing
import Darwin
import Foundation
import Network

@Suite(.serialized)
struct DaemonStatusCheckerTests {

    /// Helper: create a temp directory with an mcp-instances/ subdirectory.
    private func makeTempInstanceDir() throws -> (tempDir: URL, instancesDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let instancesDir = tempDir // instanceDirectoryOverride points directly to the "mcp-instances" dir
        try FileManager.default.createDirectory(at: instancesDir, withIntermediateDirectories: true)
        return (tempDir, instancesDir)
    }

    /// Helper: write an instance JSON file with the given wsPort.
    private func writeInstanceFile(in dir: URL, instanceID: String, mcpPort: UInt16 = 12345, wsPort: UInt16? = nil) throws {
        var info = MCPInstanceInfo(mcpPort: mcpPort)
        info.wsPort = wsPort
        info.pid = Int32(ProcessInfo.processInfo.processIdentifier)
        info.createdAt = Date().timeIntervalSince1970
        let file = dir.appendingPathComponent("\(instanceID).json")
        try info.write(to: file)
    }

    // MARK: - Instance File Detection

    @Test("Returns false when instance file does not exist")
    @MainActor
    func noInstanceFile() async throws {
        let (tempDir, instancesDir) = try makeTempInstanceDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let instanceID = UUID().uuidString
        let checker = DaemonStatusChecker()
        checker.instanceDirectoryOverride = instancesDir
        checker.startChecking(instanceID: instanceID, appGroupContainerURL: nil)

        #expect(checker.checkInstanceFile() == false)
        checker.stopChecking()
    }

    @Test("Returns false when instance file has no wsPort")
    @MainActor
    func instanceFileNoWSPort() async throws {
        let (tempDir, instancesDir) = try makeTempInstanceDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let instanceID = UUID().uuidString
        try writeInstanceFile(in: instancesDir, instanceID: instanceID, wsPort: nil)

        let checker = DaemonStatusChecker()
        checker.instanceDirectoryOverride = instancesDir
        checker.startChecking(instanceID: instanceID, appGroupContainerURL: nil)

        #expect(checker.checkInstanceFile() == false)
        checker.stopChecking()
    }

    @Test("Returns false when instance file has wsPort of zero")
    @MainActor
    func instanceFileZeroWSPort() async throws {
        let (tempDir, instancesDir) = try makeTempInstanceDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let instanceID = UUID().uuidString
        try writeInstanceFile(in: instancesDir, instanceID: instanceID, wsPort: 0)

        let checker = DaemonStatusChecker()
        checker.instanceDirectoryOverride = instancesDir
        checker.startChecking(instanceID: instanceID, appGroupContainerURL: nil)

        #expect(checker.checkInstanceFile() == false)
        checker.stopChecking()
    }

    @Test("Returns true when instance file has valid wsPort")
    @MainActor
    func instanceFileValidWSPort() async throws {
        let (tempDir, instancesDir) = try makeTempInstanceDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let instanceID = UUID().uuidString
        try writeInstanceFile(in: instancesDir, instanceID: instanceID, wsPort: 8765)

        let checker = DaemonStatusChecker()
        checker.instanceDirectoryOverride = instancesDir
        checker.startChecking(instanceID: instanceID, appGroupContainerURL: nil)

        #expect(checker.checkInstanceFile() == true)
        checker.stopChecking()
    }

    @Test("Returns false for a different instance's file")
    @MainActor
    func wrongInstanceFile() async throws {
        let (tempDir, instancesDir) = try makeTempInstanceDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let myID = UUID().uuidString
        let otherID = UUID().uuidString
        // Write a file for a different instance
        try writeInstanceFile(in: instancesDir, instanceID: otherID, wsPort: 8765)

        let checker = DaemonStatusChecker()
        checker.instanceDirectoryOverride = instancesDir
        checker.startChecking(instanceID: myID, appGroupContainerURL: nil)

        #expect(checker.checkInstanceFile() == false)
        checker.stopChecking()
    }

    // MARK: - Polling

    @Test("startChecking sets isDaemonAvailable immediately from instance file")
    @MainActor
    func startCheckingSetsInitialState() async throws {
        let (tempDir, instancesDir) = try makeTempInstanceDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let instanceID = UUID().uuidString
        try writeInstanceFile(in: instancesDir, instanceID: instanceID, wsPort: 9999)

        let checker = DaemonStatusChecker()
        checker.instanceDirectoryOverride = instancesDir

        #expect(checker.isDaemonAvailable == false, "Should be false before startChecking")
        checker.startChecking(instanceID: instanceID, appGroupContainerURL: nil)
        #expect(checker.isDaemonAvailable == true, "Should be true after startChecking with valid instance file")
        checker.stopChecking()
    }

    @Test("startChecking sets false when no instance file")
    @MainActor
    func startCheckingNoInstanceFile() async throws {
        let (tempDir, instancesDir) = try makeTempInstanceDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let instanceID = UUID().uuidString
        let checker = DaemonStatusChecker()
        checker.instanceDirectoryOverride = instancesDir

        checker.startChecking(instanceID: instanceID, appGroupContainerURL: nil)
        #expect(checker.isDaemonAvailable == false)
        checker.stopChecking()
    }

    @Test("Polling detects when daemon appears")
    @MainActor
    func pollingDetectsDaemonAppearing() async throws {
        let (tempDir, instancesDir) = try makeTempInstanceDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let instanceID = UUID().uuidString
        let checker = DaemonStatusChecker(pollInterval: 0.1)
        checker.instanceDirectoryOverride = instancesDir

        checker.startChecking(instanceID: instanceID, appGroupContainerURL: nil)
        #expect(checker.isDaemonAvailable == false)

        // Simulate terminal app writing wsPort back
        try writeInstanceFile(in: instancesDir, instanceID: instanceID, wsPort: 8765)

        // Wait for polling to pick it up
        try await Task.sleep(for: .milliseconds(300))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        #expect(checker.isDaemonAvailable == true, "Polling should detect daemon appeared")
        checker.stopChecking()
    }

    @Test("Polling detects when daemon disappears")
    @MainActor
    func pollingDetectsDaemonDisappearing() async throws {
        let (tempDir, instancesDir) = try makeTempInstanceDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let instanceID = UUID().uuidString
        try writeInstanceFile(in: instancesDir, instanceID: instanceID, wsPort: 8765)

        let checker = DaemonStatusChecker(pollInterval: 0.1)
        checker.instanceDirectoryOverride = instancesDir

        checker.startChecking(instanceID: instanceID, appGroupContainerURL: nil)
        #expect(checker.isDaemonAvailable == true)

        // Simulate daemon removing instance file
        let file = instancesDir.appendingPathComponent("\(instanceID).json")
        try FileManager.default.removeItem(at: file)

        // Wait for polling to pick it up
        try await Task.sleep(for: .milliseconds(300))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        #expect(checker.isDaemonAvailable == false, "Polling should detect daemon disappeared")
        checker.stopChecking()
    }

    // MARK: - Connectivity Check (no instanceDirectoryOverride)

    @Test("Returns false when instance file exists but nothing is listening (stale)")
    @MainActor
    func staleInstanceFile() async throws {
        let container = AppGroupContainer.url
        let instancesDir = container.appendingPathComponent("mcp-instances")
        try FileManager.default.createDirectory(at: instancesDir, withIntermediateDirectories: true)

        let instanceID = "test-stale-\(UUID().uuidString)"
        let file = instancesDir.appendingPathComponent("\(instanceID).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // Write a wsPort where nothing is listening
        try writeInstanceFile(in: instancesDir, instanceID: instanceID, wsPort: 59999)

        let checker = DaemonStatusChecker()
        // NOT setting instanceDirectoryOverride — real connectivity check runs
        checker.startChecking(instanceID: instanceID, appGroupContainerURL: container)
        #expect(checker.checkInstanceFile() == false,
                "Should return false when wsPort exists but daemon is not listening")
        checker.stopChecking()
    }

    @Test("stopChecking stops the timer")
    @MainActor
    func stopCheckingStopsTimer() async throws {
        let (tempDir, instancesDir) = try makeTempInstanceDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let instanceID = UUID().uuidString
        let checker = DaemonStatusChecker(pollInterval: 0.1)
        checker.instanceDirectoryOverride = instancesDir

        checker.startChecking(instanceID: instanceID, appGroupContainerURL: nil)
        #expect(checker.isDaemonAvailable == false)
        checker.stopChecking()

        // Write instance file after stopping — should NOT be detected
        try writeInstanceFile(in: instancesDir, instanceID: instanceID, wsPort: 8765)

        try await Task.sleep(for: .milliseconds(300))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        #expect(checker.isDaemonAvailable == false, "Should not detect changes after stopChecking")
    }

    // MARK: - MCPInstanceInfo

    @Test("MCPInstanceInfo round-trips through JSON")
    func instanceInfoRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var info = MCPInstanceInfo(mcpPort: 12345)
        info.wsPort = 54321
        info.pid = 99999
        info.createdAt = 1712500000

        let file = tempDir.appendingPathComponent("test.json")
        try info.write(to: file)

        let read = MCPInstanceInfo.read(from: file)
        #expect(read != nil)
        #expect(read?.mcpPort == 12345)
        #expect(read?.wsPort == 54321)
        #expect(read?.pid == 99999)
        #expect(read?.createdAt == 1712500000)
    }

    @Test("MCPInstanceInfo with nil wsPort")
    func instanceInfoNilWSPort() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let info = MCPInstanceInfo(mcpPort: 12345)
        let file = tempDir.appendingPathComponent("test.json")
        try info.write(to: file)

        let read = MCPInstanceInfo.read(from: file)
        #expect(read != nil)
        #expect(read?.mcpPort == 12345)
        #expect(read?.wsPort == nil)
    }

    @Test("MCPInstanceInfo read returns nil for missing file")
    func instanceInfoMissingFile() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent.json")
        #expect(MCPInstanceInfo.read(from: file) == nil)
    }

    @Test("MCPInstanceInfo read returns nil for invalid JSON")
    func instanceInfoInvalidJSON() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("test.json")
        try "not json".write(to: file, atomically: true, encoding: .utf8)

        #expect(MCPInstanceInfo.read(from: file) == nil)
    }
}
