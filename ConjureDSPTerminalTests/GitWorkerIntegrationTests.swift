//
//  GitWorkerIntegrationTests.swift
//  ConjureDSPTerminalTests
//
//  Drives GitWorker + real /usr/bin/git against a temp directory to verify
//  the end-to-end IPC pipeline works. Each test:
//    1. Creates a temp App Group directory
//    2. Instantiates GitWorker
//    3. Writes one or more request JSON files to git-queue/requests/
//    4. Invokes checkForRequests()
//    5. Reads result JSON files from git-queue/results/
//    6. Asserts git state on disk
//

import Testing
import Foundation
@testable import ConjureDSPTerminal

@Suite("GitWorker — real git integration")
struct GitWorkerIntegrationTests {

    // MARK: - Fixtures

    /// Creates a temp directory representing the App Group container and a
    /// ready-to-use GitWorker rooted at it. Also returns a Presets/ subdir
    /// that tests use as the "repo root".
    private func makeWorker() throws -> (GitWorker, appGroup: URL, presets: URL) {
        let appGroup = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorkerIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appGroup, withIntermediateDirectories: true)

        guard let worker = GitWorker(appGroupURL: appGroup) else {
            throw TestError("GitWorker failed to locate a git binary")
        }

        let presets = appGroup.appendingPathComponent("Presets", isDirectory: true)
        try FileManager.default.createDirectory(at: presets, withIntermediateDirectories: true)

        return (worker, appGroup, presets)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Write a request JSON, invoke the worker's drain loop, read back the
    /// corresponding result file. Fails the test if no result appears.
    private func roundtrip(
        worker: GitWorker,
        appGroup: URL,
        request: GitWorker.Request
    ) async throws -> GitWorker.Result {
        let queueRoot = appGroup.appendingPathComponent("git-queue", isDirectory: true)
        let requestsDir = queueRoot.appendingPathComponent("requests", isDirectory: true)
        let resultsDir = queueRoot.appendingPathComponent("results", isDirectory: true)

        let requestURL = requestsDir.appendingPathComponent("req-\(request.requestId).json")
        let data = try JSONEncoder().encode(request)
        try data.write(to: requestURL, options: .atomic)

        await worker.checkForRequests()

        let resultURL = resultsDir.appendingPathComponent("res-\(request.requestId).json")
        guard FileManager.default.fileExists(atPath: resultURL.path) else {
            throw TestError("No result file produced at \(resultURL.path)")
        }
        let resultData = try Foundation.Data(contentsOf: resultURL)
        let decoded = try JSONDecoder().decode(GitWorker.Result.self, from: resultData)
        // Mimic what the real extension-side GitQueueClient does: the result
        // file is consumed by the caller and removed. Without this cleanup
        // later tests that inspect results/ directory contents (e.g.
        // queueDrainInOrder) see ghost files from previous roundtrips.
        try? FileManager.default.removeItem(at: resultURL)
        return decoded
    }

    // MARK: - Tests

    @Test("GitWorker can locate a git binary")
    func locatesGit() async throws {
        let (worker, appGroup, _) = try makeWorker()
        defer { cleanup(appGroup) }

        // If we got here, init succeeded. Sanity-check the path exists.
        #expect(FileManager.default.isExecutableFile(atPath: worker.gitPath),
                "gitPath should be an executable: \(worker.gitPath)")
    }

    @Test("initIfNeeded on empty directory creates .git and initial commit")
    func initOnEmptyRepo() async throws {
        let (worker, appGroup, presets) = try makeWorker()
        defer { cleanup(appGroup) }

        let req = GitWorker.Request(
            requestId: UUID().uuidString,
            command: .initIfNeeded,
            repoPath: presets.path,
            timestamp: Date().timeIntervalSince1970,
            params: .init(defaultBranch: "main", userName: "Tester", userEmail: "test@local")
        )

        let result = try await roundtrip(worker: worker, appGroup: appGroup, request: req)
        #expect(result.success, "init should succeed: \(result.error ?? "")")
        #expect(result.data?.initialized == true, "should report initialized=true on first init")
        #expect(result.data?.head != nil, "HEAD should exist after init")

        let dotGit = presets.appendingPathComponent(".git")
        #expect(FileManager.default.fileExists(atPath: dotGit.path), ".git dir should exist")

        let gitignore = presets.appendingPathComponent(".gitignore")
        #expect(FileManager.default.fileExists(atPath: gitignore.path), ".gitignore should be written")

        // Verify branch is main
        let branch = runGit(in: presets, args: ["rev-parse", "--abbrev-ref", "HEAD"])
        #expect(branch.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
    }

    @Test("initIfNeeded is idempotent — second call reports initialized=false")
    func initIsIdempotent() async throws {
        let (worker, appGroup, presets) = try makeWorker()
        defer { cleanup(appGroup) }

        let first = try await roundtrip(
            worker: worker,
            appGroup: appGroup,
            request: .init(
                requestId: UUID().uuidString,
                command: .initIfNeeded,
                repoPath: presets.path,
                timestamp: 0,
                params: .init(defaultBranch: "main", userName: "Tester", userEmail: "t@local")
            )
        )
        #expect(first.success && first.data?.initialized == true)

        let second = try await roundtrip(
            worker: worker,
            appGroup: appGroup,
            request: .init(
                requestId: UUID().uuidString,
                command: .initIfNeeded,
                repoPath: presets.path,
                timestamp: 0,
                params: .init(defaultBranch: "main", userName: "Tester", userEmail: "t@local")
            )
        )
        #expect(second.success, "idempotent init should still succeed")
        #expect(second.data?.initialized == false, "second init should report initialized=false")
        #expect(second.data?.head == first.data?.head, "HEAD shouldn't have moved")
    }

    @Test("commit writes a new object and updates HEAD")
    func commitRoundtrip() async throws {
        let (worker, appGroup, presets) = try makeWorker()
        defer { cleanup(appGroup) }

        // Init first
        _ = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .initIfNeeded, repoPath: presets.path, timestamp: 0,
                           params: .init(defaultBranch: "main", userName: "Tester", userEmail: "t@local"))
        )
        let initialHead = runGit(in: presets, args: ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Write a preset file
        let preset = presets.appendingPathComponent("MyFilter.py")
        try "# hello\n".write(to: preset, atomically: true, encoding: .utf8)

        // Commit it
        let commitReq = GitWorker.Request(
            requestId: UUID().uuidString,
            command: .commit,
            repoPath: presets.path,
            timestamp: Date().timeIntervalSince1970,
            params: .init(paths: [preset.path], message: "Add MyFilter", allowEmpty: false)
        )
        let commitRes = try await roundtrip(worker: worker, appGroup: appGroup, request: commitReq)
        #expect(commitRes.success, "commit should succeed: \(commitRes.error ?? "") / \(commitRes.stderr ?? "")")
        #expect(commitRes.data?.sha != nil, "result should include new SHA")
        #expect(commitRes.data?.sha != initialHead, "new SHA should differ from initial")
        #expect((commitRes.data?.filesChanged ?? 0) >= 1, "at least one file should be reported changed")

        // Verify git log sees it
        let log = runGit(in: presets, args: ["log", "--oneline"])
        #expect(log.contains("Add MyFilter"), "git log should show the commit message; got:\n\(log)")
    }

    @Test("commit with nothing staged succeeds and reports 0 files changed")
    func commitWithNothingStaged() async throws {
        let (worker, appGroup, presets) = try makeWorker()
        defer { cleanup(appGroup) }

        _ = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .initIfNeeded, repoPath: presets.path, timestamp: 0,
                           params: .init(defaultBranch: "main", userName: "Tester", userEmail: "t@local"))
        )

        let headBefore = runGit(in: presets, args: ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let req = GitWorker.Request(
            requestId: UUID().uuidString,
            command: .commit,
            repoPath: presets.path,
            timestamp: 0,
            params: .init(paths: [], message: "nothing to commit", allowEmpty: false)
        )
        let res = try await roundtrip(worker: worker, appGroup: appGroup, request: req)
        #expect(res.success, "no-op commit should still succeed")
        #expect(res.data?.filesChanged == 0)
        #expect(res.data?.sha == headBefore, "HEAD should not have moved")
    }

    @Test("delete is recorded via commit after file is removed")
    func deleteIsCommitted() async throws {
        let (worker, appGroup, presets) = try makeWorker()
        defer { cleanup(appGroup) }

        _ = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .initIfNeeded, repoPath: presets.path, timestamp: 0,
                           params: .init(defaultBranch: "main", userName: "Tester", userEmail: "t@local"))
        )

        // Add + commit a file
        let preset = presets.appendingPathComponent("Old.py")
        try "# old\n".write(to: preset, atomically: true, encoding: .utf8)
        _ = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .commit, repoPath: presets.path, timestamp: 0,
                           params: .init(paths: [preset.path], message: "Add Old", allowEmpty: false))
        )

        // Now remove it from disk (simulating PresetManager.deletePreset)
        try FileManager.default.removeItem(at: preset)

        // Commit the removal with the same path
        let res = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .commit, repoPath: presets.path, timestamp: 0,
                           params: .init(paths: [preset.path], message: "Delete Old", allowEmpty: false))
        )
        #expect(res.success, "delete-commit should succeed: \(res.error ?? "")")

        // Verify log has both commits and file no longer tracked
        let log = runGit(in: presets, args: ["log", "--oneline"])
        #expect(log.contains("Delete Old"))
        #expect(log.contains("Add Old"))

        let tracked = runGit(in: presets, args: ["ls-files"])
        #expect(!tracked.contains("Old.py"), "file should no longer be tracked")
    }

    @Test("rename is recorded as a commit spanning old and new paths")
    func renameIsCommitted() async throws {
        let (worker, appGroup, presets) = try makeWorker()
        defer { cleanup(appGroup) }

        _ = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .initIfNeeded, repoPath: presets.path, timestamp: 0,
                           params: .init(defaultBranch: "main", userName: "Tester", userEmail: "t@local"))
        )

        let alpha = presets.appendingPathComponent("Alpha.py")
        try "# x\n".write(to: alpha, atomically: true, encoding: .utf8)
        _ = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .commit, repoPath: presets.path, timestamp: 0,
                           params: .init(paths: [alpha.path], message: "Add Alpha", allowEmpty: false))
        )

        // Move on disk
        let beta = presets.appendingPathComponent("Beta.py")
        try FileManager.default.moveItem(at: alpha, to: beta)

        // Commit with both paths (mimics PresetGitCoordinator.recordRename)
        let res = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .commit, repoPath: presets.path, timestamp: 0,
                           params: .init(paths: [alpha.path, beta.path], message: "Rename Alpha -> Beta", allowEmpty: false))
        )
        #expect(res.success, "rename commit should succeed: \(res.error ?? "")")

        let tracked = runGit(in: presets, args: ["ls-files"])
        #expect(tracked.contains("Beta.py"))
        #expect(!tracked.contains("Alpha.py"))

        let log = runGit(in: presets, args: ["log", "--oneline"])
        #expect(log.contains("Rename Alpha -> Beta"))
    }

    @Test("status reports clean / staged / untracked")
    func statusReports() async throws {
        let (worker, appGroup, presets) = try makeWorker()
        defer { cleanup(appGroup) }

        _ = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .initIfNeeded, repoPath: presets.path, timestamp: 0,
                           params: .init(defaultBranch: "main", userName: "Tester", userEmail: "t@local"))
        )

        // Clean
        let clean = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .status, repoPath: presets.path, timestamp: 0, params: .init())
        )
        #expect(clean.success)
        #expect(clean.data?.clean == true, "repo should be clean")

        // Dirty (untracked)
        try "# untracked\n".write(to: presets.appendingPathComponent("Untracked.py"), atomically: true, encoding: .utf8)
        let dirty = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .status, repoPath: presets.path, timestamp: 0, params: .init())
        )
        #expect(dirty.success)
        #expect(dirty.data?.clean == false)
        #expect(dirty.data?.untracked?.contains("Untracked.py") == true)
    }

    @Test("setRemote then removeRemote round-trip")
    func remoteLifecycle() async throws {
        let (worker, appGroup, presets) = try makeWorker()
        defer { cleanup(appGroup) }

        _ = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .initIfNeeded, repoPath: presets.path, timestamp: 0,
                           params: .init(defaultBranch: "main", userName: "Tester", userEmail: "t@local"))
        )

        // Set
        let setRes = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .setRemote, repoPath: presets.path, timestamp: 0,
                           params: .init(remoteName: "origin", remoteUrl: "https://example.com/foo.git"))
        )
        #expect(setRes.success, "setRemote should succeed: \(setRes.error ?? "")")

        let urlOut = runGit(in: presets, args: ["remote", "get-url", "origin"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(urlOut == "https://example.com/foo.git")

        // Changing the URL on an existing remote should also work (set-url path)
        let set2 = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .setRemote, repoPath: presets.path, timestamp: 0,
                           params: .init(remoteName: "origin", remoteUrl: "https://example.com/bar.git"))
        )
        #expect(set2.success, "re-set should succeed: \(set2.error ?? "")")
        let urlOut2 = runGit(in: presets, args: ["remote", "get-url", "origin"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(urlOut2 == "https://example.com/bar.git")

        // Remove
        let rmRes = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .removeRemote, repoPath: presets.path, timestamp: 0,
                           params: .init(remoteName: "origin"))
        )
        #expect(rmRes.success)
        let afterRm = runGitStatus(in: presets, args: ["remote", "get-url", "origin"])
        #expect(afterRm != 0, "origin should no longer exist")
    }

    @Test("queue order is preserved and request files are cleaned up")
    func queueDrainInOrder() async throws {
        let (worker, appGroup, presets) = try makeWorker()
        defer { cleanup(appGroup) }

        _ = try await roundtrip(
            worker: worker, appGroup: appGroup,
            request: .init(requestId: UUID().uuidString, command: .initIfNeeded, repoPath: presets.path, timestamp: 0,
                           params: .init(defaultBranch: "main", userName: "Tester", userEmail: "t@local"))
        )

        // Write two commits in a row without invoking the worker between them
        let a = presets.appendingPathComponent("A.py")
        let b = presets.appendingPathComponent("B.py")
        try "# a\n".write(to: a, atomically: true, encoding: .utf8)

        let reqA = GitWorker.Request(
            requestId: UUID().uuidString, command: .commit, repoPath: presets.path, timestamp: 0,
            params: .init(paths: [a.path], message: "Add A", allowEmpty: false)
        )
        let queueRoot = appGroup.appendingPathComponent("git-queue/requests")
        try JSONEncoder().encode(reqA).write(to: queueRoot.appendingPathComponent("req-\(reqA.requestId).json"), options: .atomic)

        try "# b\n".write(to: b, atomically: true, encoding: .utf8)
        let reqB = GitWorker.Request(
            requestId: UUID().uuidString, command: .commit, repoPath: presets.path, timestamp: 0,
            params: .init(paths: [b.path], message: "Add B", allowEmpty: false)
        )
        // Ensure mtime ordering
        try await Task.sleep(for: .milliseconds(20))
        try JSONEncoder().encode(reqB).write(to: queueRoot.appendingPathComponent("req-\(reqB.requestId).json"), options: .atomic)

        await worker.checkForRequests()

        // Both request files should be gone
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: queueRoot.path)) ?? []
        #expect(remaining.isEmpty, "all request files should be consumed, got: \(remaining)")

        // Both results should exist
        let resultsRoot = appGroup.appendingPathComponent("git-queue/results")
        let results = (try? FileManager.default.contentsOfDirectory(atPath: resultsRoot.path)) ?? []
        #expect(results.count == 2, "two result files should exist, got: \(results)")

        // Log has both commits, Add A before Add B
        let log = runGit(in: presets, args: ["log", "--oneline"])
        #expect(log.contains("Add A"))
        #expect(log.contains("Add B"))
        let lines = log.split(separator: "\n").map(String.init)
        let idxA = lines.firstIndex(where: { $0.contains("Add A") }) ?? -1
        let idxB = lines.firstIndex(where: { $0.contains("Add B") }) ?? -1
        #expect(idxA > idxB, "Add A should be older (higher line index in log) than Add B; got:\n\(log)")
    }

    // MARK: - Helpers

    private func runGit(in dir: URL, args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ""
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Foundation.Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func runGitStatus(in dir: URL, args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}

// MARK: - Test error

private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}
