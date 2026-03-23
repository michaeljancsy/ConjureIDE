import Combine
import Foundation
import os

/// Central coordinator for all GitHub features: PAT management, community browsing, personal sync.
@MainActor
final class GitHubService: ObservableObject {
    @Published var personalRepoOwner: String {
        didSet { UserDefaults.standard.set(personalRepoOwner, forKey: "github.personalRepo.owner") }
    }
    @Published var personalRepoName: String {
        didSet { UserDefaults.standard.set(personalRepoName, forKey: "github.personalRepo.name") }
    }

    let client: GitHubClient
    let communityStore: CommunityPresetStore
    let personalSync: PersonalRepoSync

    private let log = Logger(subsystem: "com.MichaelJancsy.BearBone", category: "GitHubService")

    var hasPersonalRepo: Bool {
        !personalRepoOwner.isEmpty && !personalRepoName.isEmpty
    }

    var hasToken: Bool {
        token != nil
    }

    var token: String? {
        KeychainHelper.load(key: "gitHubToken")
    }

    init(client: GitHubClient = GitHubClient()) {
        self.client = client
        self.communityStore = CommunityPresetStore(client: client)
        self.personalSync = PersonalRepoSync(client: client)
        self.personalRepoOwner = UserDefaults.standard.string(forKey: "github.personalRepo.owner") ?? ""
        self.personalRepoName = UserDefaults.standard.string(forKey: "github.personalRepo.name") ?? ""
    }

    // MARK: - Token Management

    func setToken(_ token: String?) {
        if let token, !token.isEmpty {
            try? KeychainHelper.save(key: "gitHubToken", value: token)
        } else {
            KeychainHelper.delete(key: "gitHubToken")
        }
        objectWillChange.send()
    }
}
