//
//  PresetGitCoordinator.swift
//  ConjureDSPExtension
//
//  Orchestrates git operations over the user-presets directory. The extension
//  calls in from save/delete/rename flows; the coordinator translates those
//  actions into `GitRequest`s and dispatches them via `GitQueueClient` to the
//  terminal worker.
//
//  Responsibilities:
//    - Own the commit-message preference (alwaysPrompt / alwaysTimestamp)
//      backed by UserDefaults.
//    - Own the remote URL (also UserDefaults).
//    - Trigger a one-shot `initIfNeeded` on first run.
//    - Record commits for save/delete/rename (policy: commit on explicit user
//      action only, NOT on every render-loop reload).
//    - Auto-push after a commit when a remote is configured, with a 2s
//      trailing-edge debounce so a burst of saves produces one push.
//

import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "PresetGit")

// MARK: - Public enums

enum CommitMessageMode: String, CaseIterable, Codable {
    case alwaysPrompt
    case alwaysTimestamp

    var displayName: String {
        switch self {
        case .alwaysPrompt: return "Always prompt for message on save"
        case .alwaysTimestamp: return "Always use timestamp"
        }
    }

    static let defaultMode: CommitMessageMode = .alwaysPrompt
}

enum PushState: Equatable {
    case idle
    case pushing
    case ok(Date)
    case failed(String)
}

// MARK: - Coordinator

@Observable
@MainActor
final class PresetGitCoordinator {
    // MARK: UserDefaults keys

    private enum DefaultsKey {
        static let mode = "presets.git.commitMessageMode"
        static let remoteURL = "presets.git.remoteURL"
    }

    // MARK: Observable state

    /// User preference for how commit messages are collected on save.
    var mode: CommitMessageMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.mode)
        }
    }

    /// Optional HTTPS remote URL (e.g. https://github.com/you/presets.git).
    /// Empty string → no remote configured. Not observed; mutated via setRemote/clearRemote.
    private(set) var remoteURL: String?

    /// True once `.git/HEAD` exists under `presetsURL`, either because it was
    /// already there or because `initIfNeeded` completed successfully.
    private(set) var isReady: Bool = false

    /// Most recent push outcome (for settings UI surfacing).
    private(set) var lastPushState: PushState = .idle

    /// Count of requests currently in-flight or queued (for the toolbar's
    /// "pending commit" badge when the terminal is slow or down).
    private(set) var pendingRequestCount: Int = 0

    // MARK: Dependencies

    private let presetsURL: URL
    private let appGroupURL: URL
    private let tokenProvider: () -> String?
    private let client: GitQueueClient

    // MARK: Debounce

    private var pendingPushTask: Task<Void, Never>?
    private static let pushDebounceSeconds: Double = 2.0

    // MARK: Init

    /// - Parameters:
    ///   - presetsURL: absolute path to the user presets directory
    ///     (e.g. `<AppGroup>/Presets/`). This is the repo root.
    ///   - appGroupURL: the App Group container (for queue + token files).
    ///   - tokenProvider: returns the GitHub PAT from Keychain (or nil).
    ///     Called on demand, never cached inside the coordinator.
    init(
        presetsURL: URL,
        appGroupURL: URL,
        tokenProvider: @escaping () -> String?
    ) {
        self.presetsURL = presetsURL
        self.appGroupURL = appGroupURL
        self.tokenProvider = tokenProvider
        self.client = GitQueueClient(appGroupURL: appGroupURL)

        // Hydrate from UserDefaults
        let rawMode = UserDefaults.standard.string(forKey: DefaultsKey.mode) ?? CommitMessageMode.defaultMode.rawValue
        self.mode = CommitMessageMode(rawValue: rawMode) ?? .defaultMode

        let rawURL = UserDefaults.standard.string(forKey: DefaultsKey.remoteURL) ?? ""
        self.remoteURL = rawURL.isEmpty ? nil : rawURL
    }

    /// Reset commit-message mode to the default. Bound to the "Reset to
    /// default" button in settings.
    func resetModeToDefault() {
        mode = .defaultMode
    }

    // MARK: - First-run init

    /// Call once at startup. If `<presetsURL>/.git` already exists this is
    /// just a liveness ping; otherwise the terminal worker runs `git init`.
    func initIfNeeded() async {
        let dotGit = presetsURL.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: dotGit.path) {
            isReady = true
            log.info("Preset git repo already initialized")
            return
        }

        let request = client.makeRequest(
            command: .initIfNeeded,
            repoPath: presetsURL.path,
            params: .init(
                defaultBranch: "main",
                userName: "ConjureDSP",
                userEmail: "conjuredsp@localhost"
            )
        )

        await dispatch(request, timeout: 30.0) { [weak self] result in
            guard let self else { return }
            if result.success {
                self.isReady = true
                log.info("Preset git repo initialized")
            } else {
                self.isReady = false
                log.error("initIfNeeded failed: \(result.error ?? "unknown", privacy: .public)")
            }
        }
    }

    // MARK: - Record save / delete / rename

    /// Stage the given paths and commit. Returns the commit SHA on success.
    @discardableResult
    func recordSave(paths: [URL], message: String) async -> Result<String, Error> {
        await commit(paths: paths, message: message)
    }

    @discardableResult
    func recordDelete(path: URL, message: String) async -> Result<String, Error> {
        // Delete is recorded as a commit of the removed path (`git add -A` in
        // the worker picks up tombstones).
        await commit(paths: [path], message: message)
    }

    @discardableResult
    func recordRename(oldPath: URL, newPath: URL, message: String) async -> Result<String, Error> {
        // Rename-as-two-paths: terminal's `git add -A` over both picks up the
        // delete + add, and git's rename-detection produces a rename in the log.
        await commit(paths: [oldPath, newPath], message: message)
    }

    private func commit(paths: [URL], message: String) async -> Result<String, Error> {
        guard isReady else {
            let e = NSError(
                domain: "PresetGit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Preset git repo not initialized"]
            )
            return .failure(e)
        }

        let request = client.makeRequest(
            command: .commit,
            repoPath: presetsURL.path,
            params: .init(
                paths: paths.map { $0.path },
                message: message,
                allowEmpty: false
            )
        )

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                await dispatch(request, timeout: 30.0) { result in
                    if result.success, let sha = result.data?.sha {
                        log.info("Committed \(sha.prefix(8), privacy: .public): \(message, privacy: .public)")
                        continuation.resume(returning: .success(sha))
                        // Auto-push if remote is configured
                        self.scheduleAutoPushIfNeeded()
                    } else {
                        let msg = result.error ?? "Commit failed"
                        log.error("Commit failed: \(msg, privacy: .public)")
                        let e = NSError(
                            domain: "PresetGit",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        )
                        continuation.resume(returning: .failure(e))
                    }
                }
            }
        }
    }

    // MARK: - Default commit messages

    enum CommitKind {
        case add(name: String)
        case update(name: String)
        case delete(name: String)
        case rename(old: String, new: String)
    }

    /// Generate the default commit message for a given action, honoring
    /// `mode`. When mode is `.alwaysTimestamp`, returns just the timestamp.
    func defaultMessage(for kind: CommitKind) -> String {
        switch mode {
        case .alwaysTimestamp:
            return timestampString()
        case .alwaysPrompt:
            switch kind {
            case .add(let n): return "Add \(n)"
            case .update(let n): return "Update \(n)"
            case .delete(let n): return "Delete \(n)"
            case .rename(let o, let n): return "Rename \(o) -> \(n)"
            }
        }
    }

    private func timestampString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = .current
        return fmt.string(from: Date())
    }

    // MARK: - Remote management

    func setRemote(url: String) async -> Result<Void, Error> {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(NSError(
                domain: "PresetGit", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Remote URL is empty"]
            ))
        }

        let request = client.makeRequest(
            command: .setRemote,
            repoPath: presetsURL.path,
            params: .init(remoteName: "origin", remoteUrl: trimmed)
        )

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                await dispatch(request, timeout: 15.0) { result in
                    if result.success {
                        self.remoteURL = trimmed
                        UserDefaults.standard.set(trimmed, forKey: DefaultsKey.remoteURL)
                        continuation.resume(returning: .success(()))
                    } else {
                        let msg = result.error ?? "setRemote failed"
                        continuation.resume(returning: .failure(NSError(
                            domain: "PresetGit", code: 4,
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        )))
                    }
                }
            }
        }
    }

    func clearRemote() async -> Result<Void, Error> {
        let request = client.makeRequest(
            command: .removeRemote,
            repoPath: presetsURL.path,
            params: .init(remoteName: "origin")
        )

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                await dispatch(request, timeout: 15.0) { result in
                    // Always clear local state even if the git command
                    // reported "no such remote" — we want settings to match.
                    self.remoteURL = nil
                    UserDefaults.standard.removeObject(forKey: DefaultsKey.remoteURL)
                    if result.success {
                        continuation.resume(returning: .success(()))
                    } else {
                        let msg = result.error ?? "removeRemote failed"
                        continuation.resume(returning: .failure(NSError(
                            domain: "PresetGit", code: 5,
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        )))
                    }
                }
            }
        }
    }

    // MARK: - Push

    /// Manually push. Used by the "Push now" button.
    @discardableResult
    func pushIfRemoteConfigured() async -> Result<Void, Error> {
        guard let remote = remoteURL, !remote.isEmpty else {
            lastPushState = .idle
            return .success(())
        }

        lastPushState = .pushing

        // Write a short-lived token file if we have a PAT
        var tokenFile: String?
        if let token = tokenProvider(), !token.isEmpty {
            tokenFile = try? client.writeTokenFile(token)
        }

        let request = client.makeRequest(
            command: .push,
            repoPath: presetsURL.path,
            params: .init(
                branch: "main",
                setUpstream: true,
                tokenFile: tokenFile
            )
        )

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                await dispatch(request, timeout: 60.0) { result in
                    if result.success {
                        self.lastPushState = .ok(Date())
                        log.info("Push ok (\(result.data?.commitsAhead ?? 0) commits)")
                        continuation.resume(returning: .success(()))
                    } else {
                        let msg = result.error ?? "push failed"
                        self.lastPushState = .failed(msg)
                        log.error("Push failed: \(msg, privacy: .public)")
                        continuation.resume(returning: .failure(NSError(
                            domain: "PresetGit", code: 6,
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        )))
                    }
                }
            }
        }
    }

    /// Schedule an auto-push with a 2-second trailing-edge debounce. Cancels
    /// any in-flight pending push and starts a new one. No-op when no remote
    /// is configured.
    private func scheduleAutoPushIfNeeded() {
        guard let remote = remoteURL, !remote.isEmpty else { return }
        _ = remote

        pendingPushTask?.cancel()
        pendingPushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.pushDebounceSeconds))
            guard !Task.isCancelled else { return }
            _ = await self?.pushIfRemoteConfigured()
        }
    }

    // MARK: - Dispatch helper

    private func dispatch(
        _ request: GitRequest,
        timeout: TimeInterval,
        handler: @escaping @MainActor (GitResult) -> Void
    ) async {
        pendingRequestCount += 1
        defer { pendingRequestCount -= 1 }

        do {
            let result = try await client.send(request, timeout: timeout)
            handler(result)
        } catch {
            log.error("Git \(request.command.rawValue, privacy: .public) transport error: \(error.localizedDescription, privacy: .public)")
            // Synthesize a failed result so handlers can surface a message
            let synthetic = GitResult(
                requestId: request.requestId,
                command: request.command,
                success: false,
                error: error.localizedDescription,
                stderr: nil,
                timestamp: Date().timeIntervalSince1970,
                data: nil
            )
            handler(synthetic)
        }
    }
}
