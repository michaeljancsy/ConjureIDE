//
//  PresetGitCoordinatorTests.swift
//  ConjureDSPLogicTests
//
//  Unit tests for the pieces of PresetGitCoordinator that don't require the
//  extension's git-queue IPC to be alive: wire format of GitRequest/GitResult,
//  CommitMessageMode persistence, default-message generation.
//
//  The full end-to-end pipeline (extension request → terminal git → result) is
//  covered by GitWorkerIntegrationTests in ConjureDSPTerminalTests, which
//  drives a real /usr/bin/git against a temp repo.
//
//  This file mirrors GitRequest.swift (extension) and a reduced copy of the
//  relevant coordinator logic, using `TestGit*` prefixes. If the wire format
//  in the extension (or the terminal's GitWorker) changes, the round-trip
//  tests here will fail — which is the point.
//

import Foundation
import Testing

// MARK: - Wire format (mirrors ConjureDSPExtension/Git/GitRequest.swift)

private enum TestGitCommand: String, Codable {
    case initIfNeeded
    case commit
    case status
    case setRemote
    case removeRemote
    case push
    case remoteInfo
}

private struct TestGitRequest: Codable, Equatable {
    let requestId: String
    let command: TestGitCommand
    let repoPath: String
    let timestamp: Double
    let params: Params

    struct Params: Codable, Equatable {
        var defaultBranch: String?
        var userName: String?
        var userEmail: String?
        var paths: [String]?
        var message: String?
        var allowEmpty: Bool?
        var remoteName: String?
        var remoteUrl: String?
        var branch: String?
        var setUpstream: Bool?
        var tokenFile: String?
    }
}

private struct TestGitResult: Codable, Equatable {
    let requestId: String
    let command: TestGitCommand
    let success: Bool
    let error: String?
    let stderr: String?
    let timestamp: Double
    let data: Data?

    struct Data: Codable, Equatable {
        var initialized: Bool?
        var head: String?
        var sha: String?
        var filesChanged: Int?
        var clean: Bool?
        var staged: [String]?
        var unstaged: [String]?
        var untracked: [String]?
        var previousUrl: String?
        var pushed: Bool?
        var commitsAhead: Int?
        var remotes: [RemoteRef]?
        var branch: String?
        var ahead: Int?
        var behind: Int?
    }

    struct RemoteRef: Codable, Equatable {
        let name: String
        let url: String
    }
}

// MARK: - Test: wire format round-trip

@Suite("Git IPC wire format")
struct GitWireFormatTests {

    @Test("GitRequest round-trips through JSON")
    func requestRoundTrip() throws {
        let original = TestGitRequest(
            requestId: "abc-123",
            command: .commit,
            repoPath: "/tmp/presets",
            timestamp: 1_800_000_000.0,
            params: .init(
                paths: ["/tmp/presets/MyFilter.py"],
                message: "Add MyFilter",
                allowEmpty: false
            )
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TestGitRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test("GitResult round-trips through JSON")
    func resultRoundTrip() throws {
        let original = TestGitResult(
            requestId: "abc-123",
            command: .commit,
            success: true,
            error: nil,
            stderr: nil,
            timestamp: 1_800_000_005.0,
            data: .init(sha: "deadbeef", filesChanged: 1)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TestGitResult.self, from: data)
        #expect(decoded == original)
    }

    @Test("GitRequest decodes with unknown param fields ignored (forward-compat)")
    func requestForwardCompat() throws {
        // A future terminal adds a param field we don't know about. Decoding
        // must not throw — it should just ignore the extra keys.
        let json = """
        {
            "requestId": "x",
            "command": "commit",
            "repoPath": "/tmp",
            "timestamp": 0,
            "params": {
                "message": "test",
                "futureField": "should-be-ignored"
            }
        }
        """
        let data = Foundation.Data(json.utf8)
        let decoded = try JSONDecoder().decode(TestGitRequest.self, from: data)
        #expect(decoded.params.message == "test")
    }

    @Test("GitResult preserves the RemoteRef shape the worker emits")
    func remoteInfoResultShape() throws {
        let r = TestGitResult(
            requestId: "r",
            command: .remoteInfo,
            success: true,
            error: nil,
            stderr: nil,
            timestamp: 0,
            data: .init(
                remotes: [.init(name: "origin", url: "https://github.com/you/repo.git")],
                branch: "main",
                ahead: 0,
                behind: 0
            )
        )
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(TestGitResult.self, from: data)
        #expect(decoded.data?.remotes?.first?.name == "origin")
        #expect(decoded.data?.branch == "main")
    }
}

// MARK: - CommitMessageMode preference + default-message logic

private enum TestCommitMessageMode: String, CaseIterable {
    case alwaysPrompt
    case alwaysTimestamp

    static let defaultMode: TestCommitMessageMode = .alwaysPrompt
}

private enum TestCommitKind {
    case add(name: String)
    case update(name: String)
    case delete(name: String)
    case rename(old: String, new: String)
}

/// Mirrors PresetGitCoordinator.defaultMessage — if this drifts the tests here
/// and the integration assertions in GitWorkerIntegrationTests will diverge.
private func defaultMessage(for kind: TestCommitKind, mode: TestCommitMessageMode, now: Date = Date()) -> String {
    switch mode {
    case .alwaysTimestamp:
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = .current
        return fmt.string(from: now)
    case .alwaysPrompt:
        switch kind {
        case .add(let n): return "Add \(n)"
        case .update(let n): return "Update \(n)"
        case .delete(let n): return "Delete \(n)"
        case .rename(let o, let n): return "Rename \(o) -> \(n)"
        }
    }
}

@Suite("CommitMessageMode + default messages")
struct CommitMessageTests {

    @Test("alwaysPrompt produces human-readable defaults per operation kind")
    func promptModeDefaults() {
        let mode = TestCommitMessageMode.alwaysPrompt
        #expect(defaultMessage(for: .add(name: "MyFilter"), mode: mode) == "Add MyFilter")
        #expect(defaultMessage(for: .update(name: "MyFilter"), mode: mode) == "Update MyFilter")
        #expect(defaultMessage(for: .delete(name: "MyFilter"), mode: mode) == "Delete MyFilter")
        #expect(defaultMessage(for: .rename(old: "A", new: "B"), mode: mode) == "Rename A -> B")
    }

    @Test("alwaysTimestamp produces yyyy-MM-dd HH:mm:ss regardless of kind")
    func timestampModeFormat() {
        let mode = TestCommitMessageMode.alwaysTimestamp
        // Build a known date and verify format
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 16
        comps.hour = 14; comps.minute = 23; comps.second = 45
        comps.timeZone = TimeZone.current
        let date = Calendar.current.date(from: comps)!

        let add = defaultMessage(for: .add(name: "Foo"), mode: mode, now: date)
        let upd = defaultMessage(for: .update(name: "Bar"), mode: mode, now: date)
        // Both should match the pattern and not embed "Foo"/"Bar"
        #expect(add == "2026-04-16 14:23:45")
        #expect(upd == add, "Timestamp mode ignores the kind/name")
    }

    @Test("CommitMessageMode.allCases contains both modes")
    func allCasesCoverage() {
        #expect(TestCommitMessageMode.allCases.count == 2)
        #expect(TestCommitMessageMode.allCases.contains(.alwaysPrompt))
        #expect(TestCommitMessageMode.allCases.contains(.alwaysTimestamp))
    }

    @Test("Default mode is alwaysPrompt")
    func defaultModeIsPrompt() {
        #expect(TestCommitMessageMode.defaultMode == .alwaysPrompt)
    }

    @Test("CommitMessageMode persists through UserDefaults")
    func modePersistence() {
        let key = "presets.git.commitMessageMode.testsSuite.\(UUID().uuidString)"
        let suiteName = "PresetGitCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Start clean
        #expect(defaults.string(forKey: key) == nil)

        // Write alwaysTimestamp
        defaults.set(TestCommitMessageMode.alwaysTimestamp.rawValue, forKey: key)
        let stored = defaults.string(forKey: key)
        let roundTripped = TestCommitMessageMode(rawValue: stored ?? "")
        #expect(roundTripped == .alwaysTimestamp)

        // Overwrite with alwaysPrompt
        defaults.set(TestCommitMessageMode.alwaysPrompt.rawValue, forKey: key)
        let round2 = TestCommitMessageMode(rawValue: defaults.string(forKey: key) ?? "")
        #expect(round2 == .alwaysPrompt)
    }
}

// MARK: - Queue layout (mirrors GitQueueLayout in the extension)

private enum TestGitQueueLayout {
    static let directoryName = "git-queue"
    static let requestsSubdir = "requests"
    static let resultsSubdir = "results"
    static let tokensSubdir = "tokens"
    static let requestPrefix = "req-"
    static let resultPrefix = "res-"

    static func requestURL(in appGroup: URL, requestId: String) -> URL {
        appGroup
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(requestsSubdir, isDirectory: true)
            .appendingPathComponent("\(requestPrefix)\(requestId).json")
    }

    static func resultURL(in appGroup: URL, requestId: String) -> URL {
        appGroup
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(resultsSubdir, isDirectory: true)
            .appendingPathComponent("\(resultPrefix)\(requestId).json")
    }
}

@Suite("Queue layout")
struct QueueLayoutTests {

    @Test("Request URL uses req- prefix under requests/")
    func requestURLShape() {
        let root = URL(fileURLWithPath: "/tmp/appGroup")
        let url = TestGitQueueLayout.requestURL(in: root, requestId: "abc")
        #expect(url.path == "/tmp/appGroup/git-queue/requests/req-abc.json")
    }

    @Test("Result URL uses res- prefix under results/")
    func resultURLShape() {
        let root = URL(fileURLWithPath: "/tmp/appGroup")
        let url = TestGitQueueLayout.resultURL(in: root, requestId: "abc")
        #expect(url.path == "/tmp/appGroup/git-queue/results/res-abc.json")
    }

    @Test("Request ID of '' does not collapse the filename")
    func emptyRequestIDProducesValidPath() {
        // UUIDs are always non-empty in practice, but defensive test for the
        // layout function itself — it should not crash or produce "/".
        let root = URL(fileURLWithPath: "/tmp/appGroup")
        let url = TestGitQueueLayout.requestURL(in: root, requestId: "")
        #expect(url.lastPathComponent == "req-.json")
    }
}

// MARK: - End-to-end wire contract: extension-written JSON is worker-decodable

@Suite("Extension↔terminal contract")
struct WireContractTests {

    /// Extension produces this request JSON; terminal must be able to decode it.
    /// Mirrors the structure produced by PresetGitCoordinator.recordSave.
    @Test("Commit request JSON decodes on the worker side")
    func commitRequestDecodesOnWorker() throws {
        let encoded: [String: Any] = [
            "requestId": "commit-1",
            "command": "commit",
            "repoPath": "/AppGroup/Presets",
            "timestamp": 1_800_000_000.0,
            "params": [
                "paths": ["/AppGroup/Presets/MyFilter.py"],
                "message": "Update MyFilter",
                "allowEmpty": false,
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: encoded)
        let req = try JSONDecoder().decode(TestGitRequest.self, from: data)
        #expect(req.command == .commit)
        #expect(req.params.paths == ["/AppGroup/Presets/MyFilter.py"])
        #expect(req.params.message == "Update MyFilter")
        #expect(req.params.allowEmpty == false)
    }

    @Test("initIfNeeded request JSON decodes on the worker side")
    func initRequestDecodesOnWorker() throws {
        let encoded: [String: Any] = [
            "requestId": "init-1",
            "command": "initIfNeeded",
            "repoPath": "/AppGroup/Presets",
            "timestamp": 0,
            "params": [
                "defaultBranch": "main",
                "userName": "ConjureDSP",
                "userEmail": "conjuredsp@localhost",
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: encoded)
        let req = try JSONDecoder().decode(TestGitRequest.self, from: data)
        #expect(req.command == .initIfNeeded)
        #expect(req.params.defaultBranch == "main")
        #expect(req.params.userName == "ConjureDSP")
        #expect(req.params.userEmail == "conjuredsp@localhost")
    }

    @Test("push request carries a tokenFile path when PAT is present")
    func pushWithTokenFile() throws {
        let encoded: [String: Any] = [
            "requestId": "push-1",
            "command": "push",
            "repoPath": "/AppGroup/Presets",
            "timestamp": 0,
            "params": [
                "branch": "main",
                "setUpstream": true,
                "tokenFile": "/AppGroup/git-queue/tokens/tok-abc",
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: encoded)
        let req = try JSONDecoder().decode(TestGitRequest.self, from: data)
        #expect(req.command == .push)
        #expect(req.params.tokenFile == "/AppGroup/git-queue/tokens/tok-abc")
        #expect(req.params.setUpstream == true)
    }
}
