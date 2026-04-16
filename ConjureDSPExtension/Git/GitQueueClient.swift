//
//  GitQueueClient.swift
//  ConjureDSPExtension
//
//  Thin async wrapper around the file-queue IPC defined in GitRequest.swift.
//  Writes a request, polls for the matching result, decodes, returns.
//
//  This is the low-level transport — it knows nothing about git semantics,
//  preset files, UserDefaults, or UI state. PresetGitCoordinator layers
//  policy on top.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "GitQueueClient")

/// Errors surfaced by the queue transport (not git errors from the worker).
enum GitQueueError: LocalizedError {
    case encodingFailed(Error)
    case writeRequestFailed(Error)
    case timedOut(command: GitCommand, seconds: TimeInterval)
    case decodeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let e): return "Failed to encode git request: \(e.localizedDescription)"
        case .writeRequestFailed(let e): return "Failed to write git request: \(e.localizedDescription)"
        case .timedOut(let cmd, let s): return "Git \(cmd.rawValue) timed out after \(Int(s))s (is ConjureDSP Terminal running?)"
        case .decodeFailed(let e): return "Failed to decode git result: \(e.localizedDescription)"
        }
    }
}

/// Sends a single `GitRequest` to the terminal worker and awaits the result.
///
/// The client is stateless and thread-safe — each call writes its own uniquely
/// named request file, so many can be in flight concurrently if the caller
/// wants. The coordinator serializes on purpose, but the transport does not.
struct GitQueueClient {
    let appGroupURL: URL

    /// Default poll interval matches PackageInstallManager (0.5s).
    var pollInterval: Duration = .milliseconds(500)

    init(appGroupURL: URL) {
        self.appGroupURL = appGroupURL
    }

    // MARK: - Public API

    /// Send a request and wait for its result. Throws `GitQueueError` if the
    /// transport fails or times out; the `GitResult` itself carries the git
    /// success/failure flag (the worker distinguishes "got a result" from
    /// "result says the git command failed").
    func send(_ request: GitRequest, timeout: TimeInterval = 15.0) async throws -> GitResult {
        ensureDirectories()

        // Clean any stale result file for this requestId (shouldn't exist, but be defensive)
        let resultURL = GitQueueLayout.resultURL(in: appGroupURL, requestId: request.requestId)
        try? FileManager.default.removeItem(at: resultURL)

        // Write the request
        let requestURL = GitQueueLayout.requestURL(in: appGroupURL, requestId: request.requestId)
        do {
            let data = try JSONEncoder().encode(request)
            try data.write(to: requestURL, options: .atomic)
        } catch let error as EncodingError {
            throw GitQueueError.encodingFailed(error)
        } catch {
            throw GitQueueError.writeRequestFailed(error)
        }

        log.info("Git request queued: \(request.command.rawValue, privacy: .public) (\(request.requestId, privacy: .public))")

        // Poll for the result
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: resultURL.path) {
                do {
                    let data = try Foundation.Data(contentsOf: resultURL)
                    let result = try JSONDecoder().decode(GitResult.self, from: data)
                    // Best-effort cleanup of result file
                    try? FileManager.default.removeItem(at: resultURL)
                    return result
                } catch {
                    // Partially written? Keep polling briefly before giving up.
                    try? await Task.sleep(for: pollInterval)
                    continue
                }
            }
            try? await Task.sleep(for: pollInterval)
        }

        // Timed out — request file may still be sitting there waiting for a
        // worker that never came. Leave it: when the terminal starts up it
        // will drain the backlog.
        throw GitQueueError.timedOut(command: request.command, seconds: timeout)
    }

    // MARK: - Convenience builders

    func makeRequest(command: GitCommand, repoPath: String, params: GitRequest.Params = GitRequest.Params()) -> GitRequest {
        GitRequest(
            requestId: UUID().uuidString,
            command: command,
            repoPath: repoPath,
            timestamp: Date().timeIntervalSince1970,
            params: params
        )
    }

    // MARK: - Helpers

    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: GitQueueLayout.requestsDir(in: appGroupURL), withIntermediateDirectories: true)
        try? fm.createDirectory(at: GitQueueLayout.resultsDir(in: appGroupURL), withIntermediateDirectories: true)
        try? fm.createDirectory(at: GitQueueLayout.tokensDir(in: appGroupURL), withIntermediateDirectories: true)
    }

    // MARK: - Token files (for push)

    /// Write a short-lived 0600 file containing the PAT. Returns its absolute path.
    /// Caller is expected to hand this path to the worker via `tokenFile` param.
    /// The worker is responsible for unlinking the file after spawning git.
    func writeTokenFile(_ token: String) throws -> String {
        ensureDirectories()
        let fileURL = GitQueueLayout.tokensDir(in: appGroupURL)
            .appendingPathComponent("tok-\(UUID().uuidString)")
        try token.write(to: fileURL, atomically: true, encoding: .utf8)
        // chmod 0600
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
        return fileURL.path
    }
}
