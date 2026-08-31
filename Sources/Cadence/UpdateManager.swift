import Combine
import Sparkle

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case edge

    var id: String { rawValue }
    var title: String { self == .stable ? "Stable" : "Edge" }
}

/// Sparkle owns update scheduling, signature verification, atomic installation,
/// and relaunching. Cadence only exposes the user-controlled preferences.
@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateManager()

    private static let stableFeed = "https://github.com/tapir132/whisper-live/releases/latest/download/appcast.xml"
    private static let edgeFeed = "https://github.com/tapir132/whisper-live/releases/download/edge/appcast.xml"

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
        controller.startUpdater()
        controller.updater.clearFeedURLFromUserDefaults()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        channel == .edge ? Self.edgeFeed : Self.stableFeed
    }
}
