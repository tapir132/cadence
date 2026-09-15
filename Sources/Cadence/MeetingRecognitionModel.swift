import FluidAudio
import Foundation

enum MeetingRecognitionModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case cohere
    case parakeet

    static let preferenceKey = "meetingRecognitionModel"
    var id: String { rawValue }

    var isSupported: Bool {
        if self == .cohere {
            if #available(macOS 15, *) { return true }
            return false
        }
        return true
    }

    var title: String {
        switch self {
        case .cohere: "Cohere Transcribe · Beta"
        case .parakeet: "Parakeet Unified"
        }
    }

    var detail: String {
        switch self {
        case .cohere:
            "Live text is revised after each phrase with Cohere. Models download once during setup and stay on this Mac."
        case .parakeet:
            "Fast live transcription with the original model. English, on this Mac."
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        let selected = defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .cohere
        return selected.isSupported ? selected : .parakeet
    }
}

struct CohereMeetingModelStore: Sendable {
    var store = SpeechModelStore()

    var directory: URL {
        store.modelsDirectory.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
    }

    var requiredArtifacts: [SpeechModelArtifact] {
        ModelNames.CohereTranscribe.requiredModels.sorted().map {
            SpeechModelArtifact(
                relativePath: "\(Repo.cohereTranscribeCoreml.folderName)/\($0)",
                isCompiledModel: $0.hasSuffix(".mlmodelc")
            )
        }
    }

    func install(onProgress: @escaping @Sendable (SpeechModelPreparationUpdate) -> Void) async throws {
        guard MeetingRecognitionModel.cohere.isSupported else {
            throw SpeechEngineError.modelUnavailable("Cohere requires macOS 15 or later. Select Parakeet Unified on this Mac.")
        }
        if !store.artifactsAreInstalled(requiredArtifacts) {
            onProgress(.downloading(nil))
            try await ModelHub.download(.cohereTranscribeCoreml, to: store.modelsDirectory) { progress in
                onProgress(.downloading(SpeechModelStore.aggregate(progress, base: 0, weight: 1)))
            }
        }
        try Task.checkCancellation()
        guard store.artifactsAreInstalled(requiredArtifacts) else {
            throw SpeechEngineError.modelUnavailable("The Cohere download is incomplete. Try again or select Parakeet Unified.")
        }
        onProgress(.loading())
    }
}

/// One local batch decoder, used serially by the refinement queue. Audio is
/// held only in memory and released when its phrase has been processed.
actor CohereMeetingRefiner {
    private let store: CohereMeetingModelStore
    private let pipeline = CoherePipeline()
    private var models: CoherePipeline.LoadedModels?

    init(store: CohereMeetingModelStore = CohereMeetingModelStore()) {
        self.store = store
    }

    func prepare(onProgress: @escaping @Sendable (SpeechModelPreparationUpdate) -> Void) async throws {
        guard models == nil else { return }
        try await store.install(onProgress: onProgress)
        let directory = store.directory
        let loaded = try await CoherePipeline.loadModels(
            encoderDir: directory, decoderDir: directory, vocabDir: directory,
            // `.all` spent nearly two minutes specializing the encoder's
            // Metal graph on an M2 Max. CPU/ANE avoids that first-phrase stall.
            computeUnits: .cpuAndNeuralEngine
        )
        try Task.checkCancellation()
        // Trigger first-prediction compilation during setup, before reporting
        // ready. This is generated silence in memory, never microphone access.
        _ = try await pipeline.transcribe(
            audio: [Float](repeating: 0, count: 16_000), models: loaded, maxNewTokens: 1
        )
        try Task.checkCancellation()
        models = loaded
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        guard let models else { throw SpeechEngineError.modelUnavailable("Cohere has not loaded.") }
        let result = try await pipeline.transcribe(audio: samples, models: models, language: .english)
        try Task.checkCancellation()
        // The converted decoder has a fixed token budget. Never replace a
        // complete live phrase with a result that exhausted it mid-sentence.
        guard result.tokenIds.count < CohereAsrConfig.maxSeqLen - CohereAsrConfig.Language.english.promptSequence.count + 1 else {
            throw SpeechEngineError.modelUnavailable("Cohere reached its phrase length limit.")
        }
        return result.text
    }
}

struct MeetingRefinementJob: Sendable {
    let update: MeetingTranscriptUpdate
    let samples: [Float]
}

/// Bounds both RAM and catch-up time on slower Macs. Overflow preserves the
/// already-visible Parakeet phrase instead of blocking audio capture.
struct MeetingRefinementQueue: Sendable {
    private let stream: AsyncStream<MeetingRefinementJob>
    private let continuation: AsyncStream<MeetingRefinementJob>.Continuation

    init(capacity: Int = 4) {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    }

    func submit(_ job: MeetingRefinementJob) -> Bool {
        if case .enqueued = continuation.yield(job) { return true }
        return false
    }

    func finish() { continuation.finish() }

    func run(
        refine: @escaping @Sendable ([Float]) async throws -> String,
        onUpdate: @escaping @Sendable (MeetingTranscriptUpdate) async -> Void,
        onFallback: @escaping @Sendable () async -> Void
    ) async {
        for await job in stream {
            guard !Task.isCancelled else { return }
            do {
                let text = try await refine(job.samples).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled else { return }
                guard !text.isEmpty else { await onFallback(); continue }
                await onUpdate(MeetingTranscriptUpdate(
                    id: job.update.id, speaker: job.update.speaker,
                    startTime: job.update.startTime, text: text, model: .cohere
                ))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                NSLog("Cadence Cohere phrase failed: %@", error.localizedDescription)
                await onFallback()
            }
        }
    }
}
