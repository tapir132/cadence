@preconcurrency import AVFoundation
import FluidAudio
import Foundation

struct MeetingTranscriptUpdate: Sendable {
    let id: UUID
    let speaker: MeetingSpeaker
    let startTime: TimeInterval
    let text: String
    var model: MeetingRecognitionModel = .parakeet
}

/// Owns independent recognition and voice-activity state for each input. A
/// quiet microphone, simultaneous speech, or delayed decoder cannot relabel
/// the other channel's words.
actor MeetingTranscriber {
    private let microphone = LiveSpeechTranscriber()
    private let system = LiveSpeechTranscriber()
    private var refiner: CohereMeetingRefiner?
    private var selectedModel: MeetingRecognitionModel = .parakeet

    func prepare(
        model: MeetingRecognitionModel = .parakeet,
        onProgress: @escaping @Sendable (SpeechModelPreparationUpdate) -> Void = { _ in }
    ) async throws {
        try await prepareLive(onProgress: onProgress)
        if model == .cohere { try await prepareCohere(onProgress: onProgress) }
        selectedModel = model
    }

    func prepareLive(onProgress: @escaping @Sendable (SpeechModelPreparationUpdate) -> Void) async throws {
        // Install once before the second loader accesses the shared model files.
        try await microphone.prepare(profile: .accurate, onProgress: onProgress)
        try Task.checkCancellation()
        try await system.prepare(profile: .accurate, onProgress: onProgress)
    }

    func prepareCohere(onProgress: @escaping @Sendable (SpeechModelPreparationUpdate) -> Void) async throws {
        let cohere = refiner ?? CohereMeetingRefiner()
        try await cohere.prepare(onProgress: onProgress)
        refiner = cohere
    }

    func transcribe(
        _ audio: MeetingAudioStreams,
        model: MeetingRecognitionModel? = nil,
        onFinishing: @escaping @Sendable () async -> Void = {},
        onFallback: @escaping @Sendable () async -> Void = {},
        onUpdate: @escaping @Sendable (MeetingTranscriptUpdate) async -> Void
    ) async throws {
        let activeRefiner = (model ?? selectedModel) == .cohere ? refiner : nil
        let queue = activeRefiner.map { _ in MeetingRefinementQueue() }
        let refinementTask = Task {
            if let queue, let refiner = activeRefiner {
                await queue.run(refine: { try await refiner.transcribe($0) }, onUpdate: onUpdate, onFallback: onFallback)
            }
        }
        defer { queue?.finish(); refinementTask.cancel() }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [microphone] in
                    try await microphone.transcribeMeeting(
                        audio.microphone, speaker: .you, refinementQueue: queue,
                        onFallback: onFallback, onUpdate: onUpdate
                    )
                }
                group.addTask { [system] in
                    try await system.transcribeMeeting(
                        audio.system, speaker: .them, refinementQueue: queue,
                        onFallback: onFallback, onUpdate: onUpdate
                    )
                }
                while try await group.next() != nil {}
            }
            queue?.finish()
            await onFinishing()
            await withTaskCancellationHandler {
                await refinementTask.value
            } onCancel: {
                refinementTask.cancel()
            }
            try Task.checkCancellation()
        } catch {
            queue?.finish()
            refinementTask.cancel()
            await refinementTask.value
            throw error
        }
    }
}

/// Processes one source in capture order. Updates replace the same utterance
/// even if the other channel has already added a later line to the note.
actor MeetingChannelRecognizer {
    private let manager: StreamingUnifiedAsrManager
    private let vad: VadManager
    private let speaker: MeetingSpeaker
    private var vadState = VadStreamState.initial()
    private var preRoll: [CapturedAudioChunk] = []
    private var utteranceID: UUID?
    private var utteranceStart: TimeInterval = 0
    private var lastText = ""
    private let refinementQueue: MeetingRefinementQueue?
    private let onFallback: @Sendable () async -> Void
    private var utteranceSamples: [Float] = []
    // Keep well below the Core ML decoder's 98 available output tokens, even
    // for quick speech. This also bounds each queued audio buffer to ~0.5 MB.
    static let refinementSampleLimit = 8 * 16_000

    init(
        manager: StreamingUnifiedAsrManager, vad: VadManager, speaker: MeetingSpeaker,
        refinementQueue: MeetingRefinementQueue? = nil,
        onFallback: @escaping @Sendable () async -> Void = {}
    ) {
        self.manager = manager
        self.vad = vad
        self.speaker = speaker
        self.refinementQueue = refinementQueue
        self.onFallback = onFallback
    }

    func transcribe(
        _ audio: AsyncStream<CapturedAudioChunk>,
        onUpdate: @escaping @Sendable (MeetingTranscriptUpdate) async -> Void
    ) async throws {
        try await manager.reset()
        var pending: [Float] = []
        var pendingStart: TimeInterval = 0
        do {
            for await chunk in audio {
                try Task.checkCancellation()
                guard !chunk.samples.isEmpty else { continue }
                // A device can stop delivering callbacks. Do not join speech
                // across that gap or let an old sample clock reorder new turns.
                let expected = pendingStart + Double(pending.count) / 16_000
                if pendingStart > 0, chunk.startTime - expected > 0.25 {
                    if !pending.isEmpty {
                        try await process(CapturedAudioChunk(samples: pending, startTime: pendingStart), onUpdate: onUpdate)
                    }
                    try await finishUtterance(onUpdate: onUpdate)
                    pending.removeAll(keepingCapacity: true)
                    preRoll.removeAll(keepingCapacity: true)
                    vadState = .initial()
                }
                if pending.isEmpty { pendingStart = chunk.startTime }
                pending.append(contentsOf: chunk.samples)
                while pending.count >= VadManager.chunkSize {
                    let samples = Array(pending.prefix(VadManager.chunkSize))
                    pending.removeFirst(VadManager.chunkSize)
                    try await process(CapturedAudioChunk(samples: samples, startTime: pendingStart), onUpdate: onUpdate)
                    pendingStart += Double(samples.count) / 16_000
                }
            }
            try Task.checkCancellation()
            // Stop often lands in the middle of a 256 ms VAD block.
            if !pending.isEmpty {
                try await process(CapturedAudioChunk(samples: pending, startTime: pendingStart), onUpdate: onUpdate)
            }
            try await finishUtterance(onUpdate: onUpdate)
            try await manager.reset()
        } catch {
            try? await manager.reset()
            throw error
        }
    }

    private func process(
        _ chunk: CapturedAudioChunk,
        onUpdate: @escaping @Sendable (MeetingTranscriptUpdate) async -> Void
    ) async throws {
        let result = try await vad.processStreamingChunk(chunk.samples, state: vadState)
        vadState = result.state
        if utteranceID == nil {
            preRoll.append(chunk)
            if preRoll.count > 2 { preRoll.removeFirst() }
            guard result.state.triggered else { return }
            utteranceID = UUID()
            // Date the turn by the detected speech, not the preceding silence.
            utteranceStart = chunk.startTime
            for buffered in preRoll { try await append(buffered.samples) }
            preRoll.removeAll(keepingCapacity: true)
        } else {
            try await append(chunk.samples)
        }
        if result.event?.isEnd == true || utteranceSamples.count >= Self.refinementSampleLimit {
            try await finishUtterance(onUpdate: onUpdate)
        } else {
            await publish(await manager.getPartialTranscript(), onUpdate: onUpdate)
        }
    }

    private func append(_ samples: [Float]) async throws {
        if refinementQueue != nil { utteranceSamples.append(contentsOf: samples) }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?.pointee else { throw SpeechEngineError.noInput }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
    }

    private func finishUtterance(
        onUpdate: @escaping @Sendable (MeetingTranscriptUpdate) async -> Void
    ) async throws {
        guard let id = utteranceID else { return }
        await publish(try await manager.finish(), onUpdate: onUpdate)
        if let refinementQueue, !utteranceSamples.isEmpty {
            let accepted = refinementQueue.submit(MeetingRefinementJob(
                update: MeetingTranscriptUpdate(id: id, speaker: speaker, startTime: utteranceStart, text: lastText),
                samples: utteranceSamples
            ))
            if !accepted { await onFallback() }
        }
        utteranceSamples.removeAll(keepingCapacity: true)
        try await manager.reset()
        utteranceID = nil
        lastText = ""
    }

    private func publish(
        _ rawText: String,
        onUpdate: @escaping @Sendable (MeetingTranscriptUpdate) async -> Void
    ) async {
        guard let id = utteranceID else { return }
        // A conversation is not a dictation command: keep spoken "period",
        // "new line", fillers, and names exactly as the recognizer heard them.
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != lastText else { return }
        lastText = text
        await onUpdate(MeetingTranscriptUpdate(id: id, speaker: speaker, startTime: utteranceStart, text: text))
    }
}
