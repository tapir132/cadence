import Foundation

enum MeetingModelSetupStatus: Equatable {
    case idle
    case preparing(SpeechModelPreparationUpdate)
    case ready
    case failed(String)

    var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }
}

struct MeetingModelSetup: Equatable {
    var live: MeetingModelSetupStatus = .idle
    var cohere: MeetingModelSetupStatus = .idle

    func status(for model: MeetingRecognitionModel) -> MeetingModelSetupStatus {
        live == .ready && model == .cohere ? cohere : live
    }

    func recordingModel(preferred: MeetingRecognitionModel) -> MeetingRecognitionModel {
        preferred == .cohere && cohere == .ready ? .cohere : .parakeet
    }
}

/// Setup belongs to the app's lifetime, not a recording. Both launch and a
/// recording that arrives during setup await the same live-model task. Cohere
/// can continue preparing without delaying the first captured words.
@MainActor
final class MeetingModelPreparation {
    typealias Prepare = @Sendable (@escaping @Sendable (SpeechModelPreparationUpdate) -> Void) async throws -> Void

    private(set) var state = MeetingModelSetup() {
        didSet { onChange(state) }
    }
    var onChange: (MeetingModelSetup) -> Void = { _ in }
    private let prepareLive: Prepare
    private let prepareCohere: Prepare
    private var liveTask: Task<Void, Error>?
    private var cohereTask: Task<Void, Error>?
    private var liveGeneration = UUID()
    private var cohereGeneration = UUID()

    init(prepareLive: @escaping Prepare, prepareCohere: @escaping Prepare) {
        self.prepareLive = prepareLive
        self.prepareCohere = prepareCohere
    }

    func start(for model: MeetingRecognitionModel) {
        let live = startLive()
        guard model == .cohere, cohereTask == nil, state.cohere != .ready else { return }
        let generation = UUID()
        cohereGeneration = generation
        state.cohere = .preparing(.loading())
        cohereTask = Task { [prepareCohere] in
            do {
                try await live.value
                try await prepareCohere { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.cohereGeneration == generation, self.state.cohere.isPreparing else { return }
                        self.state.cohere = .preparing(update)
                    }
                }
                state.cohere = .ready
                cohereTask = nil
            } catch {
                state.cohere = .failed(error.localizedDescription)
                cohereTask = nil
                throw error
            }
        }
    }

    func ensureLiveReady() async throws {
        try await startLive().value
    }

    private func startLive() -> Task<Void, Error> {
        if let liveTask { return liveTask }
        if state.live == .ready { return Task {} }
        let generation = UUID()
        liveGeneration = generation
        state.live = .preparing(.loading())
        let task = Task { [prepareLive] in
            do {
                try await prepareLive { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.liveGeneration == generation, self.state.live.isPreparing else { return }
                        self.state.live = .preparing(update)
                    }
                }
                state.live = .ready
                liveTask = nil
            } catch {
                state.live = .failed(error.localizedDescription)
                liveTask = nil
                throw error
            }
        }
        liveTask = task
        return task
    }
}
