import Combine
import Foundation
import os

/// PAT management + remote-URL storage for the git-backed preset library.
///
/// Historically this type also ran bespoke REST-API sync over a separate
/// `RepoPresets/` directory. That layer has been replaced by real git
/// operations (see `PresetGitCoordinator`), so this class has shrunk to just
/// the two pieces of state that remain genuinely per-user:
///   - PAT (Keychain, required for `git push` to github.com over HTTPS)
///   - Remote URL (UserDefaults; also surfaced by the coordinator for UI)
///
/// The `remoteURL` here mirrors the coordinator's copy — the coordinator is
/// the source of truth when set from the Settings UI, this field is just a
/// convenience for code paths that need to check "do we have a remote?"
/// without pulling in the coordinator.
@MainActor
final class GitHubService: ObservableObject {
    private static let remoteURLDefaultsKey = "presets.git.remoteURL"
    private static let tokenKeychainKey = "gitHubToken"

    @Published var remoteURL: String {
        didSet {
            if remoteURL.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.remoteURLDefaultsKey)
            } else {
                UserDefaults.standard.set(remoteURL, forKey: Self.remoteURLDefaultsKey)
            }
        }
    }

    private let log = Logger(subsystem: "com.MichaelJancsy.ConjureDSP", category: "GitHubService")

    var hasRemote: Bool { !remoteURL.isEmpty }

    var hasToken: Bool { token != nil }

    var token: String? {
        KeychainHelper.load(key: Self.tokenKeychainKey)
    }

    init() {
        self.remoteURL = UserDefaults.standard.string(forKey: Self.remoteURLDefaultsKey) ?? ""
    }

    // MARK: - Token management

    func setToken(_ token: String?) {
        if let token, !token.isEmpty {
            try? KeychainHelper.save(key: Self.tokenKeychainKey, value: token)
        } else {
            KeychainHelper.delete(key: Self.tokenKeychainKey)
        }
        objectWillChange.send()
    }
}
