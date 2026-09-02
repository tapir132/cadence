import Combine
import Sparkle

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case edge

    var id: String { rawValue }
    var title: String { self == .stable ? "Release" : "Edge" }
}

/// Sparkle owns update scheduling, signature verification, atomic installation,
/// and relaunching. Cadence only exposes the user-controlled preferences.
@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateManager()

    private static let stableFeed = "https://github.com/tapir132/cadence/releases/latest/download/appcast.xml"
    private static let edgeFeed = "https://github.com/tapir132/cadence/releases/download/edge/appcast.xml"

    lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    @Published private(set) var canCheckForUpdates = false
    @Published var channel: UpdateChannel = .stable {
        didSet {
            guard isConfigured else { return }
            UserDefaults.standard.set(channel.rawValue, forKey: "updateChannel")
            if hasStarted { controller.updater.resetUpdateCycleAfterShortDelay() }
        }
    }
    @Published var automaticallyChecks = true {
        didSet {
            guard isConfigured else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }
    @Published var automaticallyDownloads = true {
        didSet {
            guard isConfigured else { return }
            controller.updater.automaticallyDownloadsUpdates = automaticallyDownloads
        }
    }

    private var isConfigured = false
    private var hasStarted = false
    private var startupProbeInProgress = false
    private var startupProbeFoundUpdate = false
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
        if let saved = UserDefaults.standard.string(forKey: "updateChannel"),
           let channel = UpdateChannel(rawValue: saved) {
            self.channel = channel
        }
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        canCheckForUpdates = controller.updater.canCheckForUpdates
        isConfigured = true

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func start() {
        guard !hasStarted, Bundle.main.bundleURL.pathExtension == "app" else { return }
        hasStarted = true
        // The delegate feed must win on the very first update cycle, including
        // after a channel change left an older URL in Sparkle's defaults.
        controller.updater.clearFeedURLFromUserDefaults()
        controller.startUpdater()

        // Sparkle's normal scheduler checks only after its interval elapses and
        // may install automatic updates without surfacing a window. A launch
        // probe is silent when current; if it finds a newer build, the follow-up
        // user-facing cycle brings Sparkle's standard update prompt into focus.
        guard controller.updater.automaticallyChecksForUpdates else { return }
        startupProbeInProgress = true
        startupProbeFoundUpdate = false
        controller.updater.checkForUpdateInformation()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if startupProbeInProgress { startupProbeFoundUpdate = true }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard startupProbeInProgress, updateCheck == .updateInformation else { return }
        let shouldPrompt = startupProbeFoundUpdate
        startupProbeInProgress = false
        startupProbeFoundUpdate = false
        guard shouldPrompt else { return }

        // The probe's session has ended at this callback. Start the visible
        // cycle on the next run-loop turn so Sparkle can present its standard UI.
        DispatchQueue.main.async { [weak self] in
            self?.controller.checkForUpdates(nil)
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        channel == .edge ? Self.edgeFeed : Self.stableFeed
    }
}
