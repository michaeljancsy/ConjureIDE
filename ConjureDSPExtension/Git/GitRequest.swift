//
//  GitRequest.swift
//  ConjureDSPExtension
//
//  Shared JSON shapes for the git-queue IPC between the AU extension
//  (request producer) and ConjureDSPTerminal (request consumer / git executor).
//
//  The terminal has an equivalent copy of these shapes inline in GitWorker.swift
//  so the two targets don't need to share a source file via pbxproj membership.
//  Matches the convention used for PackageInstallManager ↔ PackageInstaller.
//
//  Wire-level layout inside the App Group container:
//      <AppGroup>/git-queue/requests/req-<uuid>.json   (extension writes)
//      <AppGroup>/git-queue/results/res-<uuid>.json    (terminal writes)
//
//  The terminal polls requests/ in its reconcile loop, processes in mtime order,
//  writes the result file, then deletes the request file. The extension polls
//  results/ for the specific requestId it's waiting on.
//

import Foundation

// MARK: - Command

enum GitCommand: String, Codable {
    case initIfNeeded
    case commit
    case status
    case setRemote
    case removeRemote
    case push
    case remoteInfo
}

// MARK: - Request

struct GitRequest: Codable {
    let requestId: String
    let command: GitCommand
    let repoPath: String
    let timestamp: Double
    let params: Params

    /// All per-command parameters as optionals. Only the fields relevant to
    /// `command` are populated; the rest are nil. Keeps the wire format flat
    /// and avoids the heterogeneous-enum Codable dance.
    struct Params: Codable {
        // initIfNeeded
        var defaultBranch: String?
        var userName: String?
        var userEmail: String?

        // commit
        var paths: [String]?
        var message: String?
        var allowEmpty: Bool?

        // setRemote / removeRemote
        var remoteName: String?
        var remoteUrl: String?

        // push
        var branch: String?
        var setUpstream: Bool?
        /// Absolute path in the App Group container to a 0600-perm file
        /// containing just the PAT. The terminal reads it via a git credential
        /// helper, then unlinks it.
        var tokenFile: String?

        init(
            defaultBranch: String? = nil,
            userName: String? = nil,
            userEmail: String? = nil,
            paths: [String]? = nil,
            message: String? = nil,
            allowEmpty: Bool? = nil,
            remoteName: String? = nil,
            remoteUrl: String? = nil,
            branch: String? = nil,
            setUpstream: Bool? = nil,
            tokenFile: String? = nil
        ) {
            self.defaultBranch = defaultBranch
            self.userName = userName
            self.userEmail = userEmail
            self.paths = paths
            self.message = message
            self.allowEmpty = allowEmpty
            self.remoteName = remoteName
            self.remoteUrl = remoteUrl
            self.branch = branch
            self.setUpstream = setUpstream
            self.tokenFile = tokenFile
        }
    }
}

// MARK: - Result

struct GitResult: Codable {
    let requestId: String
    let command: GitCommand
    let success: Bool
    let error: String?
    let stderr: String?
    let timestamp: Double
    let data: Data?

    struct Data: Codable {
        // initIfNeeded
        var initialized: Bool?
        var head: String?

        // commit
        var sha: String?
        var filesChanged: Int?

        // status
        var clean: Bool?
        var staged: [String]?
        var unstaged: [String]?
        var untracked: [String]?

        // setRemote / removeRemote
        var previousUrl: String?

        // push
        var pushed: Bool?
        var commitsAhead: Int?

        // remoteInfo
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

// MARK: - Queue layout

enum GitQueueLayout {
    static let directoryName = "git-queue"
    static let requestsSubdir = "requests"
    static let resultsSubdir = "results"
    static let tokensSubdir = "tokens"

    static let requestPrefix = "req-"
    static let resultPrefix = "res-"
    static let jsonExtension = "json"

    /// The queue root inside the App Group container.
    static func root(in appGroup: URL) -> URL {
        appGroup.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func requestsDir(in appGroup: URL) -> URL {
        root(in: appGroup).appendingPathComponent(requestsSubdir, isDirectory: true)
    }

    static func resultsDir(in appGroup: URL) -> URL {
        root(in: appGroup).appendingPathComponent(resultsSubdir, isDirectory: true)
    }

    static func tokensDir(in appGroup: URL) -> URL {
        root(in: appGroup).appendingPathComponent(tokensSubdir, isDirectory: true)
    }

    static func requestURL(in appGroup: URL, requestId: String) -> URL {
        requestsDir(in: appGroup).appendingPathComponent("\(requestPrefix)\(requestId).\(jsonExtension)")
    }

    static func resultURL(in appGroup: URL, requestId: String) -> URL {
        resultsDir(in: appGroup).appendingPathComponent("\(resultPrefix)\(requestId).\(jsonExtension)")
    }
}
