//
//  GitWorker.swift
//  ConjureDSPTerminal
//
//  Watches <AppGroup>/git-queue/requests/ for GitRequest JSON files written
//  by the AU extension, executes them by shelling out to the system git,
//  and writes GitResult JSON files to <AppGroup>/git-queue/results/.
//
//  The wire-level types mirror ConjureDSPExtension/Git/GitRequest.swift.
//  Keep them in sync manually — this is the same pattern PackageInstaller
//  uses with PackageInstallManager.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP.Terminal", category: "GitWorker")

final class GitWorker {
    let appGroupURL: URL
    let gitPath: String

    // MARK: - Wire types (must match ConjureDSPExtension/Git/GitRequest.swift)

    enum Command: String, Codable {
        case initIfNeeded
        case commit
        case status
        case setRemote
        case removeRemote
        case push
        case remoteInfo
    }

    struct Request: Codable {
        let requestId: String
        let command: Command
        let repoPath: String
        let timestamp: Double
        let params: Params

        struct Params: Codable {
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

    struct Result: Codable {
        let requestId: String
        let command: Command
        let success: Bool
        let error: String?
        let stderr: String?
        let timestamp: Double
        let data: Data?

        struct Data: Codable {
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

        struct RemoteRef: Codable {
            let name: String
            let url: String
        }
    }

    // MARK: - Init

    /// Fails if no usable `git` binary can be located.
    init?(appGroupURL: URL) {
        self.appGroupURL = appGroupURL
        guard let resolved = Self.locateGit() else {
            log.error("No git binary found via xcrun, /usr/bin/git, or PATH")
            return nil
        }
        self.gitPath = resolved
        log.info("GitWorker using git at \(resolved, privacy: .public)")

        ensureDirectories()
    }

    private static func locateGit() -> String? {
        // 1. xcrun -f git (Command Line Tools or Xcode-provided)
        if let xcrunResolved = runProcessSync("/usr/bin/xcrun", arguments: ["-f", "git"]).output?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !xcrunResolved.isEmpty,
           FileManager.default.isExecutableFile(atPath: xcrunResolved) {
            return xcrunResolved
        }

        // 2. /usr/bin/git (Apple's shim — triggers CLT install if needed)
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/git") {
            return "/usr/bin/git"
        }

        // 3. `which git` on PATH
        if let pathGit = runProcessSync("/usr/bin/which", arguments: ["git"]).output?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pathGit.isEmpty,
           FileManager.default.isExecutableFile(atPath: pathGit) {
            return pathGit
        }

        return nil
    }

    // MARK: - Queue layout

    private var queueRoot: URL { appGroupURL.appendingPathComponent("git-queue", isDirectory: true) }
    private var requestsDir: URL { queueRoot.appendingPathComponent("requests", isDirectory: true) }
    private var resultsDir: URL { queueRoot.appendingPathComponent("results", isDirectory: true) }
    private var tokensDir: URL { queueRoot.appendingPathComponent("tokens", isDirectory: true) }

    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: requestsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: tokensDir, withIntermediateDirectories: true)
    }

    // MARK: - Main entry (called from TerminalAppServer's reconcile loop)

    /// Check the requests directory and process every request file (oldest first).
    /// Called once per ~500ms tick from TerminalAppServer.startWatching.
    func checkForRequests() async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: requestsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let files = entries
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("req-") }
            .sorted { a, b in
                let ta = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let tb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return ta < tb
            }

        for file in files {
            await processRequestFile(at: file)
        }
    }

    private func processRequestFile(at file: URL) async {
        let fm = FileManager.default
        guard let data = try? Foundation.Data(contentsOf: file) else { return }
        let request: Request
        do {
            request = try JSONDecoder().decode(Request.self, from: data)
        } catch {
            // Partially written / corrupt — nuke it so we don't loop
            log.warning("Could not decode request at \(file.lastPathComponent, privacy: .public) — removing")
            try? fm.removeItem(at: file)
            return
        }

        log.info("Processing \(request.command.rawValue, privacy: .public) for repo \(request.repoPath, privacy: .public)")

        let result = await handle(request)

        // Write result
        let resultURL = resultsDir.appendingPathComponent("res-\(request.requestId).json")
        if let encoded = try? JSONEncoder().encode(result) {
            try? encoded.write(to: resultURL, options: .atomic)
        } else {
            log.error("Failed to encode result for \(request.requestId, privacy: .public)")
        }

        // Delete request file (processing done)
        try? fm.removeItem(at: file)
    }

    // MARK: - Command dispatch

    private func handle(_ req: Request) async -> Result {
        switch req.command {
        case .initIfNeeded: return await handleInit(req)
        case .commit:       return await handleCommit(req)
        case .status:       return await handleStatus(req)
        case .setRemote:    return await handleSetRemote(req)
        case .removeRemote: return await handleRemoveRemote(req)
        case .push:         return await handlePush(req)
        case .remoteInfo:   return await handleRemoteInfo(req)
        }
    }

    // MARK: initIfNeeded

    private func handleInit(_ req: Request) async -> Result {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: req.repoPath)

        // Ensure the preset dir itself exists
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)

        let dotGit = repo.appendingPathComponent(".git")
        if fm.fileExists(atPath: dotGit.path) {
            return makeResult(req, success: true, data: .init(initialized: false, head: currentHead(at: repo)))
        }

        let branch = req.params.defaultBranch ?? "main"
        let userName = req.params.userName ?? "ConjureDSP"
        let userEmail = req.params.userEmail ?? "conjuredsp@localhost"

        // git init --initial-branch=<branch>
        let initResult = runGit(at: repo, args: ["init", "--initial-branch=\(branch)"])
        guard initResult.exitCode == 0 else {
            return makeResult(req, success: false, error: "git init failed", stderr: initResult.stderr)
        }

        // Repo-local user identity (doesn't touch ~/.gitconfig)
        _ = runGit(at: repo, args: ["config", "user.name", userName])
        _ = runGit(at: repo, args: ["config", "user.email", userEmail])
        // Don't prompt for creds over HTTPS
        _ = runGit(at: repo, args: ["config", "credential.helper", ""])

        // Write a .gitignore
        let gitignore = repo.appendingPathComponent(".gitignore")
        let gitignoreContents = ".DS_Store\n*.swp\n*.swo\n"
        try? gitignoreContents.write(to: gitignore, atomically: true, encoding: .utf8)

        // Create an initial empty commit so HEAD exists
        let addResult = runGit(at: repo, args: ["add", ".gitignore"])
        guard addResult.exitCode == 0 else {
            return makeResult(req, success: false, error: "git add .gitignore failed", stderr: addResult.stderr)
        }
        let commitResult = runGit(at: repo, args: ["commit", "-m", "Initialize preset library"])
        guard commitResult.exitCode == 0 else {
            return makeResult(req, success: false, error: "initial commit failed", stderr: commitResult.stderr)
        }

        return makeResult(req, success: true, data: .init(initialized: true, head: currentHead(at: repo)))
    }

    // MARK: commit

    private func handleCommit(_ req: Request) async -> Result {
        let repo = URL(fileURLWithPath: req.repoPath)
        let message = req.params.message ?? "Update"
        let allowEmpty = req.params.allowEmpty ?? false

        // Stage specific paths if provided, else stage everything
        if let paths = req.params.paths, !paths.isEmpty {
            // `git add -A` with explicit paths handles add + delete + rename
            var addArgs: [String] = ["add", "-A", "--"]
            addArgs.append(contentsOf: paths)
            let addResult = runGit(at: repo, args: addArgs)
            guard addResult.exitCode == 0 else {
                return makeResult(req, success: false, error: "git add failed", stderr: addResult.stderr)
            }
        } else {
            let addResult = runGit(at: repo, args: ["add", "-A"])
            guard addResult.exitCode == 0 else {
                return makeResult(req, success: false, error: "git add failed", stderr: addResult.stderr)
            }
        }

        // If nothing to commit and allowEmpty=false, report current HEAD as success
        let statusResult = runGit(at: repo, args: ["status", "--porcelain"])
        let nothingStaged = (statusResult.stdout ?? "").isEmpty
        if nothingStaged && !allowEmpty {
            return makeResult(req, success: true, data: .init(sha: currentHead(at: repo), filesChanged: 0))
        }

        // Count files changed (rough: count porcelain lines)
        let filesChanged = (statusResult.stdout ?? "")
            .split(whereSeparator: { $0.isNewline })
            .count

        var commitArgs = ["commit", "-m", message]
        if allowEmpty { commitArgs.append("--allow-empty") }
        let commitResult = runGit(at: repo, args: commitArgs)
        guard commitResult.exitCode == 0 else {
            return makeResult(req, success: false, error: "git commit failed", stderr: commitResult.stderr)
        }

        return makeResult(req, success: true, data: .init(sha: currentHead(at: repo), filesChanged: filesChanged))
    }

    // MARK: status

    private func handleStatus(_ req: Request) async -> Result {
        let repo = URL(fileURLWithPath: req.repoPath)
        let porc = runGit(at: repo, args: ["status", "--porcelain"])
        guard porc.exitCode == 0 else {
            return makeResult(req, success: false, error: "git status failed", stderr: porc.stderr)
        }

        var staged: [String] = []
        var unstaged: [String] = []
        var untracked: [String] = []

        for raw in (porc.stdout ?? "").split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            guard line.count >= 3 else { continue }
            let idx = line.index(line.startIndex, offsetBy: 2)
            let path = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            let chars = Array(line)
            if chars[0] == "?" && chars[1] == "?" {
                untracked.append(String(path))
            } else {
                if chars[0] != " " { staged.append(String(path)) }
                if chars[1] != " " { unstaged.append(String(path)) }
            }
        }

        let clean = staged.isEmpty && unstaged.isEmpty && untracked.isEmpty
        return makeResult(req, success: true, data: .init(
            clean: clean,
            staged: staged,
            unstaged: unstaged,
            untracked: untracked
        ))
    }

    // MARK: setRemote / removeRemote

    private func handleSetRemote(_ req: Request) async -> Result {
        let repo = URL(fileURLWithPath: req.repoPath)
        let name = req.params.remoteName ?? "origin"
        guard let url = req.params.remoteUrl, !url.isEmpty else {
            return makeResult(req, success: false, error: "remoteUrl missing")
        }

        // Capture previous URL for the result payload
        let prev = runGit(at: repo, args: ["remote", "get-url", name]).stdout?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Try add first; if it exists, set-url
        let addResult = runGit(at: repo, args: ["remote", "add", name, url])
        if addResult.exitCode != 0 {
            let setResult = runGit(at: repo, args: ["remote", "set-url", name, url])
            guard setResult.exitCode == 0 else {
                return makeResult(req, success: false, error: "git remote set-url failed", stderr: setResult.stderr)
            }
        }

        return makeResult(req, success: true, data: .init(previousUrl: prev))
    }

    private func handleRemoveRemote(_ req: Request) async -> Result {
        let repo = URL(fileURLWithPath: req.repoPath)
        let name = req.params.remoteName ?? "origin"
        let prev = runGit(at: repo, args: ["remote", "get-url", name]).stdout?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let removeResult = runGit(at: repo, args: ["remote", "remove", name])
        // Treat "remote not found" as success — idempotent
        return makeResult(
            req,
            success: true,
            stderr: removeResult.exitCode == 0 ? nil : removeResult.stderr,
            data: .init(previousUrl: prev)
        )
    }

    // MARK: push

    private func handlePush(_ req: Request) async -> Result {
        let repo = URL(fileURLWithPath: req.repoPath)
        let remote = req.params.remoteName ?? "origin"
        let branch = req.params.branch ?? "main"
        let setUpstream = req.params.setUpstream ?? true

        var pushArgs: [String] = []
        // Inline credential helper that reads the PAT from the token file if supplied
        if let tokenFile = req.params.tokenFile, !tokenFile.isEmpty,
           FileManager.default.isReadableFile(atPath: tokenFile) {
            // Git calls /bin/sh -c '<helper>' for any helper starting with "!"
            let helper = "!f() { echo username=x-access-token; echo \"password=$(cat \(shellQuote(tokenFile)))\"; }; f"
            pushArgs.append(contentsOf: ["-c", "credential.helper=", "-c", "credential.helper=\(helper)"])
        }
        pushArgs.append("push")
        if setUpstream { pushArgs.append("-u") }
        pushArgs.append(contentsOf: [remote, branch])

        let pushResult = runGit(at: repo, args: pushArgs, extraEnv: ["GIT_TERMINAL_PROMPT": "0"])

        // Always best-effort unlink the token file
        if let tokenFile = req.params.tokenFile {
            try? FileManager.default.removeItem(atPath: tokenFile)
        }

        guard pushResult.exitCode == 0 else {
            return makeResult(req, success: false, error: "git push failed", stderr: pushResult.stderr)
        }

        // Gauge commits ahead/behind via for-each-ref (cheap heuristic)
        let aheadBehind = runGit(at: repo, args: [
            "rev-list", "--left-right", "--count", "\(branch)...\(remote)/\(branch)"
        ]).stdout ?? ""
        let ahead = Int(aheadBehind.split(separator: "\t").first ?? "0") ?? 0

        return makeResult(req, success: true, data: .init(pushed: true, commitsAhead: ahead))
    }

    // MARK: remoteInfo

    private func handleRemoteInfo(_ req: Request) async -> Result {
        let repo = URL(fileURLWithPath: req.repoPath)

        // Remotes
        let list = runGit(at: repo, args: ["remote", "-v"]).stdout ?? ""
        var remotesByName: [String: String] = [:]
        for line in list.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2 else { continue }
            remotesByName[String(parts[0])] = String(parts[1])
        }
        let remotes = remotesByName.map { Result.RemoteRef(name: $0.key, url: $0.value) }

        // Current branch
        let branch = runGit(at: repo, args: ["rev-parse", "--abbrev-ref", "HEAD"]).stdout?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "main"

        // Ahead/behind vs origin/<branch> (silent if not present)
        var ahead = 0
        var behind = 0
        let aheadBehind = runGit(at: repo, args: [
            "rev-list", "--left-right", "--count", "\(branch)...origin/\(branch)"
        ])
        if aheadBehind.exitCode == 0, let s = aheadBehind.stdout {
            let parts = s.split(whereSeparator: { $0.isWhitespace })
            if parts.count == 2 {
                ahead = Int(parts[0]) ?? 0
                behind = Int(parts[1]) ?? 0
            }
        }

        return makeResult(req, success: true, data: .init(
            remotes: remotes,
            branch: branch,
            ahead: ahead,
            behind: behind
        ))
    }

    // MARK: - Helpers

    private func currentHead(at repo: URL) -> String? {
        let r = runGit(at: repo, args: ["rev-parse", "HEAD"])
        guard r.exitCode == 0 else { return nil }
        return r.stdout?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeResult(
        _ req: Request,
        success: Bool,
        error: String? = nil,
        stderr: String? = nil,
        data: Result.Data? = nil
    ) -> Result {
        Result(
            requestId: req.requestId,
            command: req.command,
            success: success,
            error: error,
            stderr: stderr,
            timestamp: Date().timeIntervalSince1970,
            data: data
        )
    }

    fileprivate struct ProcessOutcome {
        let exitCode: Int32
        let stdout: String?
        let stderr: String?
    }

    private func runGit(at repo: URL, args: [String], extraEnv: [String: String] = [:]) -> ProcessOutcome {
        var fullArgs = ["-C", repo.path]
        fullArgs.append(contentsOf: args)
        return Self.runProcess(path: gitPath, arguments: fullArgs, extraEnv: extraEnv)
    }

    fileprivate static func runProcess(
        path: String,
        arguments: [String],
        extraEnv: [String: String] = [:]
    ) -> ProcessOutcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ProcessOutcome(exitCode: -1, stdout: nil, stderr: error.localizedDescription)
        }

        let outData = try? outPipe.fileHandleForReading.readToEnd()
        let errData = try? errPipe.fileHandleForReading.readToEnd()
        return ProcessOutcome(
            exitCode: p.terminationStatus,
            stdout: outData.flatMap { String(data: $0, encoding: .utf8) },
            stderr: errData.flatMap { String(data: $0, encoding: .utf8) }
        )
    }

    private func shellQuote(_ s: String) -> String {
        // Single-quote for sh: escape embedded single quotes.
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// Small sync helper used during init to locate git.
private func runProcessSync(_ path: String, arguments: [String]) -> (output: String?, exitCode: Int32) {
    let outcome = GitWorker.runProcess(path: path, arguments: arguments)
    return (outcome.stdout, outcome.exitCode)
}
