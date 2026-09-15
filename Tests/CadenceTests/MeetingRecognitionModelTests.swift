import Foundation
import Testing
@testable import Cadence

@MainActor
@Test func meetingModelDefaultsToCohereAndPersistsTheFallbackChoice() throws {
    let suite = "cadence-meeting-model-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MeetingNoteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json"))
    let model = MeetingNotesModel(store: store, polls: false, defaults: defaults)
    let preferred: MeetingRecognitionModel = MeetingRecognitionModel.cohere.isSupported ? .cohere : .parakeet
    #expect(model.recognitionModel == preferred)
    model.selectRecognitionModel(.parakeet)
    let reopened = MeetingNotesModel(store: store, polls: false, defaults: defaults)
    #expect(reopened.recognitionModel == .parakeet)
    reopened.selectRecognitionModel(.cohere)
    #expect(MeetingRecognitionModel.load(from: defaults) == preferred)
    defaults.set("unknown-future-model", forKey: MeetingRecognitionModel.preferenceKey)
    #expect(MeetingRecognitionModel.load(from: defaults) == preferred)
}

@Test func optionalCohereArtifactsDoNotExpandTheDictationDownload() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-cohere-store-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SpeechModelStore(applicationSupportDirectory: directory)
    let cohere = CohereMeetingModelStore(store: store)
    #expect(cohere.requiredArtifacts.count == 3)
    #expect(cohere.requiredArtifacts.filter(\.isCompiledModel).count == 2)
    #expect(!store.requiredArtifacts.contains { $0.relativePath.contains("cohere") })
    #expect(!store.artifactsAreInstalled(cohere.requiredArtifacts))
    for artifact in cohere.requiredArtifacts {
        let url = store.modelsDirectory.appendingPathComponent(artifact.relativePath)
        let parent = artifact.isCompiledModel ? url : url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data([0]).write(to: artifact.isCompiledModel ? url.appendingPathComponent("coremldata.bin") : url)
    }
    #expect(store.artifactsAreInstalled(cohere.requiredArtifacts))
    let encoder = try #require(cohere.requiredArtifacts.first { $0.isCompiledModel })
    try Data([0]).write(to: store.modelsDirectory.appendingPathComponent(encoder.relativePath).appendingPathComponent("weights.partial"))
    #expect(!store.artifactsAreInstalled(cohere.requiredArtifacts))
}

@Test func delayedCohereRevisionsKeepSourceIdentityAndCaptureOrder() async {
    let queue = MeetingRefinementQueue()
    let recorder = RefinementTestRecorder()
    let remote = MeetingTranscriptUpdate(id: UUID(), speaker: .them, startTime: 1, text: "Look at the bored.")
    let local = MeetingTranscriptUpdate(id: UUID(), speaker: .you, startTime: 2, text: "Yes.")
    await recorder.apply(remote)
    await recorder.apply(local)
    #expect(queue.submit(MeetingRefinementJob(update: remote, samples: [1])))
    queue.finish()
    await queue.run(refine: { _ in "Look at the board." }, onUpdate: { await recorder.apply($0) }, onFallback: {})
    let note = await recorder.note
    #expect(note.lines.map(\.id) == [remote.id, local.id])
    #expect(note.lines.map(\.speaker) == [.them, .you])
    #expect(note.lines.map(\.text) == ["Look at the board.", "Yes."])
}

@Test func refinementBacklogFailureAndEmptyOutputPreserveLiveWords() async {
    let queue = MeetingRefinementQueue(capacity: 2)
    let recorder = RefinementTestRecorder()
    let update = MeetingTranscriptUpdate(id: UUID(), speaker: .you, startTime: 1, text: "Keep these words.")
    await recorder.apply(update)
    #expect(queue.submit(MeetingRefinementJob(update: update, samples: [0])))
    #expect(queue.submit(MeetingRefinementJob(update: update, samples: [1])))
    #expect(!queue.submit(MeetingRefinementJob(update: update, samples: [2])))
    queue.finish()
    await queue.run(refine: { samples in
        if samples == [0] { throw SpeechEngineError.noSpeech }
        return " "
    }, onUpdate: { await recorder.apply($0) }, onFallback: { await recorder.fallback() })
    #expect(await recorder.fallbacks == 2)
    #expect(await recorder.note.lines.map(\.text) == ["Keep these words."])
}

@Test func cancellationDoesNotPublishAnInFlightRefinement() async {
    let queue = MeetingRefinementQueue()
    let recorder = RefinementTestRecorder()
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let update = MeetingTranscriptUpdate(id: UUID(), speaker: .them, startTime: 1, text: "Original.")
    await recorder.apply(update)
    #expect(queue.submit(MeetingRefinementJob(update: update, samples: [1])))
    queue.finish()
    let task = Task {
        await queue.run(refine: { _ in
            entered.continuation.yield(())
            for await _ in release.stream { break }
            return "Late replacement."
        }, onUpdate: { await recorder.apply($0) }, onFallback: { await recorder.fallback() })
    }
    for await _ in entered.stream { break }
    task.cancel()
    release.continuation.finish()
    entered.continuation.finish()
    await task.value
    #expect(await recorder.note.lines.map(\.text) == ["Original."])
    #expect(await recorder.fallbacks == 0)
}

private actor RefinementTestRecorder {
    private(set) var note = MeetingNote(id: UUID(), date: .now, title: "Test", duration: 0, lines: [], thoughts: "")
    private(set) var fallbacks = 0
    func apply(_ update: MeetingTranscriptUpdate) { note.apply(update) }
    func fallback() { fallbacks += 1 }
}
