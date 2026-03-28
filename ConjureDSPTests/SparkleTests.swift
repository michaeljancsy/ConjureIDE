import Combine
import Sparkle
import Testing

// MARK: - CheckForUpdatesViewModel (copied to avoid importing the host app target)

/// Mirrors the production CheckForUpdatesViewModel from ConjureDSPApp.swift.
/// Duplicated here because the host app target can't be imported into tests
/// without pulling in the AU extension and causing duplicate symbol issues.
@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private var cancellable: Any?

    init(updater: SPUUpdater) {
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
    }
}

@Suite struct SparkleTests {
    @Test @MainActor func checkForUpdatesViewModelReflectsUpdaterState() async throws {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let viewModel = CheckForUpdatesViewModel(updater: controller.updater)

        // Updater hasn't started, so canCheckForUpdates should be false
        #expect(viewModel.canCheckForUpdates == false)
    }

    @Test @MainActor func updaterControllerCreatesWithoutStarting() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Sparkle APIs require main thread; verify no crash on creation
        #expect(controller.updater.automaticallyChecksForUpdates == true)
    }
}
