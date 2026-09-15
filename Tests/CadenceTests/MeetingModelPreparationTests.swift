import Foundation
import Testing
@testable import Cadence

/// Mock loaders only. These tests do not load a model, open a device, or play audio.
@MainActor
@Suite struct MeetingModelPreparationTests {
    @Test func liveNotesBecomeReadyWhileCohereIsStillPreparing() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let probe = PreparationProbe()
        let preparation = MeetingModelPreparation(prepareLive: { _ in
            await probe.live()
        }, prepareCohere: { _ in
            await probe.cohere()
            entered.continuation.yield(())
            for await _ in release.stream { break }
        })
        preparation.start(for: .cohere)
        for await _ in entered.stream { break }
        try await preparation.ensureLiveReady()
        #expect(preparation.state.live == .ready)
        #expect(preparation.state.cohere.isPreparing)
        #expect(preparation.state.recordingModel(preferred: .cohere) == .parakeet)
        preparation.start(for: .cohere)
        #expect(await probe.liveCalls == 1)
        #expect(await probe.cohereCalls == 1)
        release.continuation.finish()
        entered.continuation.finish()
        await settle { preparation.state.cohere == .ready }
        #expect(preparation.state.recordingModel(preferred: .cohere) == .cohere)
        #expect(preparation.state.recordingModel(preferred: .parakeet) == .parakeet)
        preparation.start(for: .parakeet)
        preparation.start(for: .cohere)
        #expect(await probe.liveCalls == 1)
        #expect(await probe.cohereCalls == 1)
    }

    @Test func launchAndMeetingShareSetupAndCancellationDoesNotDiscardIt() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let probe = PreparationProbe()
        let preparation = MeetingModelPreparation(prepareLive: { _ in
            await probe.live()
            entered.continuation.yield(())
            for await _ in release.stream { break }
        }, prepareCohere: { _ in })
        preparation.start(for: .parakeet)
        for await _ in entered.stream { break }
        let cancelledMeeting = Task { try await preparation.ensureLiveReady() }
        cancelledMeeting.cancel()
        preparation.start(for: .parakeet)
        release.continuation.finish()
        entered.continuation.finish()
        try await preparation.ensureLiveReady()
        _ = await cancelledMeeting.result
        #expect(preparation.state.live == .ready)
        #expect(await probe.liveCalls == 1)
    }

    @Test func failedCohereSetupCanRetryWithoutReloadingLiveModels() async throws {
        let probe = PreparationProbe()
        let preparation = MeetingModelPreparation(prepareLive: { _ in
            await probe.live()
        }, prepareCohere: { _ in
            await probe.cohere()
            if await probe.cohereCalls == 1 { throw SpeechEngineError.noSpeech }
        })
        preparation.start(for: .cohere)
        await settle { if case .failed = preparation.state.cohere { true } else { false } }
        #expect(preparation.state.live == .ready)
        #expect(preparation.state.recordingModel(preferred: .cohere) == .parakeet)
        preparation.start(for: .cohere)
        await settle { preparation.state.cohere == .ready }
        #expect(await probe.liveCalls == 1)
        #expect(await probe.cohereCalls == 2)
    }

    @Test func lateProgressCannotTurnAReadyModelBackIntoLoading() async throws {
        let probe = PreparationProbe()
        let preparation = MeetingModelPreparation(prepareLive: { progress in
            await probe.remember(progress)
        }, prepareCohere: { _ in })
        try await preparation.ensureLiveReady()
        await probe.sendLateProgress()
        try await Task.sleep(for: .milliseconds(20))
        #expect(preparation.state.live == .ready)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition())
    }
}

private actor PreparationProbe {
    private(set) var liveCalls = 0
    private(set) var cohereCalls = 0
    private var progress: (@Sendable (SpeechModelPreparationUpdate) -> Void)?
    func live() { liveCalls += 1 }
    func cohere() { cohereCalls += 1 }
    func remember(_ progress: @escaping @Sendable (SpeechModelPreparationUpdate) -> Void) { self.progress = progress }
    func sendLateProgress() { progress?(.downloading(0.5)) }
}
