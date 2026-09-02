@preconcurrency import AVFoundation
import FluidAudio
import Foundation

enum SpeechEngineError: LocalizedError {
    case permissions
    case noInput
    case noSpeech
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .permissions:
            "Microphone access is required."
        case .noInput:
            "No microphone input format is available."
        case .noSpeech:
            "No speech was detected."
        case let .modelUnavailable(message):
            "The local speech model is unavailable: \(message)"
        }
    }
}

enum SpeechModelStatus: Equatable {
    case preparing(progress: Double?)
    case ready
    case failed(String)
}

extension RecognitionProfile {
    var unifiedConfig: UnifiedConfig {
        switch self {
        case .fast:
            UnifiedConfig(leftFrames: 70, chunkFrames: 2, rightFrames: 2)
        case .accurate:
            UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7)
        }
    }
}

/// Owns the append-only Parakeet Unified decoder and Silero voice-activity
/// detector. A pause flushes the visible tail immediately. Cadence preserves
/// the decoder stream for a grammatical continuation and closes it only at a
/// sentence boundary, retaining language context across mid-sentence pauses.
actor LiveSpeechTranscriber {
    private static let vadChunkSize = VadManager.chunkSize
    private static let preRollSampleCount = VadManager.chunkSize * 2
    // Silero has already observed sustained silence before it reports an end.
    // Two additional blocks keep a brief mid-thought hesitation open without
    // making sentence punctuation lag noticeably behind the visible tail.
    private static let uncertainPauseGraceSamples = VadManager.chunkSize * 2

    private struct PreparedModels: Sendable {
        let manager: StreamingUnifiedAsrManager
        let vad: VadManager
    }

    private struct ModelPreparation {
        let id: UUID
        let profile: RecognitionProfile
        let task: Task<PreparedModels, Error>
    }

    private var manager: StreamingUnifiedAsrManager?
    private var vad: VadManager?
    private var loadedProfile: RecognitionProfile?
    private var desiredProfile: RecognitionProfile = .fast
    private var preparedManagers: [RecognitionProfile: StreamingUnifiedAsrManager] = [:]
    private var preparation: ModelPreparation?

    func prepare(
        profile: RecognitionProfile = .fast,
        onProgress: @escaping @Sendable (Double?) -> Void
    ) async throws {
        desiredProfile = profile
        if let prepared = preparedManagers[profile], vad != nil {
            manager = prepared
            loadedProfile = profile
            return
        }
        if manager != nil, vad != nil, loadedProfile == profile { return }
        if let preparation {
            try await complete(preparation)
            // A newer Settings choice supersedes this caller while model loading
            // is suspended. The completed model stays warm for a later switch,
            // but it must not silently become the active recognizer.
            guard desiredProfile == profile else { return }
            if let prepared = preparedManagers[profile], vad != nil {
                manager = prepared
                loadedProfile = profile
                return
            }
        }

        let existingVad = vad
        let task = Task {
            let modelWeight = existingVad == nil ? 0.92 : 1.0
            let manager = StreamingUnifiedAsrManager(
                config: profile.unifiedConfig
            )
            try await manager.loadModels(progressHandler: { progress in
                onProgress(progress.fractionCompleted * modelWeight)
            })
            let preparedVad: VadManager
            if let existingVad {
                preparedVad = existingVad
            } else {
                preparedVad = try await VadManager(progressHandler: { progress in
                    onProgress(0.92 + progress.fractionCompleted * 0.08)
                })
            }
            return PreparedModels(manager: manager, vad: preparedVad)
        }
        let pending = ModelPreparation(id: UUID(), profile: profile, task: task)
        preparation = pending
        try await complete(pending)
    }

    private func complete(_ pending: ModelPreparation) async throws {
        do {
            let prepared = try await pending.task.value
            guard preparation?.id == pending.id else { return }
            preparedManagers[pending.profile] = prepared.manager
            vad = prepared.vad
            preparation = nil
            if desiredProfile == pending.profile {
                manager = prepared.manager
                loadedProfile = pending.profile
            }
        } catch {
            if preparation?.id == pending.id { preparation = nil }
            throw error
        }
    }

    func transcribe(
        _ audio: AsyncStream<[Float]>,
        cleanupEnabled: Bool = false,
        dictionaryTerms: [String] = [],
        snippets: [TextSnippet] = [],
        insertionDelay: Duration = .zero,
        onUpdate: @escaping @Sendable (LiveTranscriptUpdate) async -> Void
    ) async throws -> String {
        guard let manager, let vad else {
            throw SpeechEngineError.modelUnavailable("Model preparation has not finished.")
        }

        try await manager.reset()
        var emitter = LiveTranscriptEmitter(
            cleanupEnabled: cleanupEnabled,
            dictionaryTerms: dictionaryTerms,
            snippets: snippets,
            insertionDelay: insertionDelay
        )
        var vadState = VadStreamState.initial()
        var pendingSamples: [Float] = []
        var preRoll: [Float] = []
        var segmentActive = false
        var pendingBoundary: PauseBoundaryDecision?
        var pendingSilenceSamples = 0

        do {
            for await samples in audio {
                try Task.checkCancellation()
                pendingSamples.append(contentsOf: samples)
                while pendingSamples.count >= Self.vadChunkSize {
                    let chunk = Array(pendingSamples.prefix(Self.vadChunkSize))
                    pendingSamples.removeFirst(Self.vadChunkSize)
                    try await process(
                        chunk,
                        manager: manager,
                        vad: vad,
                        vadState: &vadState,
                        preRoll: &preRoll,
                        segmentActive: &segmentActive,
                        pendingBoundary: &pendingBoundary,
                        pendingSilenceSamples: &pendingSilenceSamples,
                        emitter: &emitter,
                        onUpdate: onUpdate
                    )
                }
            }

            // The tap normally ends between VAD blocks. Never discard the last
            // fraction of a word just because it is shorter than 256 ms.
            if !pendingSamples.isEmpty {
                if segmentActive {
                    try await decode(
                        pendingSamples,
                        manager: manager,
                        emitter: &emitter,
                        onUpdate: onUpdate
                    )
                } else {
                    try await process(
                        pendingSamples,
                        manager: manager,
                        vad: vad,
                        vadState: &vadState,
                        preRoll: &preRoll,
                        segmentActive: &segmentActive,
                        pendingBoundary: &pendingBoundary,
                        pendingSilenceSamples: &pendingSilenceSamples,
                        emitter: &emitter,
                        onUpdate: onUpdate
                    )
                }
            }

            if segmentActive || emitter.hasOpenSegment {
                try await finalizeSegment(
                    manager: manager,
                    emitter: &emitter,
                    continuesAfterPause: false,
                    onUpdate: onUpdate
                )
            }

            let transcript = emitter.completedText.trimmingCharacters(in: .whitespacesAndNewlines)
            try await manager.reset()
            guard !transcript.isEmpty else { throw SpeechEngineError.noSpeech }
            return transcript
        } catch {
            try? await manager.reset()
            throw error
        }
    }

    private func process(
        _ chunk: [Float],
        manager: StreamingUnifiedAsrManager,
        vad: VadManager,
        vadState: inout VadStreamState,
        preRoll: inout [Float],
        segmentActive: inout Bool,
        pendingBoundary: inout PauseBoundaryDecision?,
        pendingSilenceSamples: inout Int,
        emitter: inout LiveTranscriptEmitter,
        onUpdate: @escaping @Sendable (LiveTranscriptUpdate) async -> Void
    ) async throws {
        let wasActive = segmentActive
        let result = try await vad.processStreamingChunk(chunk, state: vadState)
        vadState = result.state

        if wasActive {
            try await decode(chunk, manager: manager, emitter: &emitter, onUpdate: onUpdate)
        } else {
            preRoll.append(contentsOf: chunk)
            if preRoll.count > Self.preRollSampleCount {
                preRoll.removeFirst(preRoll.count - Self.preRollSampleCount)
            }
            if result.event?.isStart == true || result.state.triggered {
                pendingBoundary = nil
                pendingSilenceSamples = 0
                segmentActive = true
                let bufferedSpeech = preRoll
                preRoll.removeAll(keepingCapacity: true)
                try await decode(
                    bufferedSpeech,
                    manager: manager,
                    emitter: &emitter,
                    onUpdate: onUpdate
                )
            } else if pendingBoundary == .uncertain {
                pendingSilenceSamples += chunk.count
                if pendingSilenceSamples >= Self.uncertainPauseGraceSamples {
                    try await finalizeSegment(
                        manager: manager,
                        emitter: &emitter,
                        continuesAfterPause: true,
                        onUpdate: onUpdate
                    )
                    try await manager.reset()
                    pendingBoundary = nil
                    pendingSilenceSamples = 0
                }
            }
        }

        if result.event?.isEnd == true, segmentActive {
            let partial = await manager.getPartialTranscript()
            let boundary = emitter.pauseBoundaryDecision(for: partial)
            switch boundary {
            case .complete:
                try await finalizeSegment(
                    manager: manager,
                    emitter: &emitter,
                    continuesAfterPause: true,
                    onUpdate: onUpdate
                )
                try await manager.reset()
                pendingBoundary = nil
            case .continuation, .uncertain:
                if let update = try emitter.flushPauseTail(partial) {
                    await onUpdate(update)
                }
                pendingBoundary = boundary
            }
            pendingSilenceSamples = 0
            segmentActive = false
            preRoll.removeAll(keepingCapacity: true)
        }
    }

    private func decode(
        _ samples: [Float],
        manager: StreamingUnifiedAsrManager,
        emitter: inout LiveTranscriptEmitter,
        onUpdate: @escaping @Sendable (LiveTranscriptUpdate) async -> Void
    ) async throws {
        guard !samples.isEmpty else { return }
        let buffer = try Self.audioBuffer(samples)
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
        let partial = await manager.getPartialTranscript()
        if let update = try emitter.consume(partial) {
            await onUpdate(update)
        }
    }

    private func finalizeSegment(
        manager: StreamingUnifiedAsrManager,
        emitter: inout LiveTranscriptEmitter,
        continuesAfterPause: Bool,
        onUpdate: @escaping @Sendable (LiveTranscriptUpdate) async -> Void
    ) async throws {
        let final = try await manager.finish()
        if let update = try emitter.finalize(final, continuesAfterPause: continuesAfterPause) {
            await onUpdate(update)
        }
    }

    private nonisolated static func audioBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?.pointee else {
            throw SpeechEngineError.noInput
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }
        return buffer
    }
}

/// Captures microphone input and yields ordered 16 kHz mono Float32 chunks.
/// AsyncStream gives the decoder one serialized consumer, so Core ML work can
/// never reorder tap callbacks or silently lose audio while it is busy.
final class AudioCaptureEngine: @unchecked Sendable {
    private static let sampleRate = 16_000.0

    private var audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var manuallyMixInputToMono = false
    private var recordingGeneration: UInt64 = 0
    private var isRecording = false
    private let lock = NSLock()
    private var onLevel: (@Sendable (Float) -> Void)?
    private var continuation: AsyncStream<[Float]>.Continuation?

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    nonisolated static func requestPermissions() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws -> AsyncStream<[Float]> {
        guard Self.microphoneAuthorized else { throw SpeechEngineError.permissions }
        cancel()

        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Self.sampleRate,
                  channels: 1,
                  interleaved: false
              ) else { throw SpeechEngineError.noInput }

        let sourceFormat = converterSourceFormat(for: inputFormat)
        let mixToMono = inputFormat.channelCount > 1 && sourceFormat.channelCount == 1
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw SpeechEngineError.noInput
        }

        var streamContinuation: AsyncStream<[Float]>.Continuation?
        let stream = AsyncStream<[Float]>(bufferingPolicy: .unbounded) { continuation in
            streamContinuation = continuation
        }
        guard let streamContinuation else { throw SpeechEngineError.noInput }

        lock.lock()
        recordingGeneration &+= 1
        self.converter = converter
        converterInputFormat = sourceFormat
        manuallyMixInputToMono = mixToMono
        self.onLevel = onLevel
        continuation = streamContinuation
        isRecording = true
        let generation = recordingGeneration
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer, targetFormat: targetFormat, generation: generation)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            return stream
        } catch {
            cancel()
            throw error
        }
    }

    func finish() {
        stopAudioEngine()
        endStream()
    }

    func cancel() {
        stopAudioEngine()
        endStream()
    }

    private func endStream() {
        lock.lock()
        isRecording = false
        recordingGeneration &+= 1
        let activeContinuation = continuation
        continuation = nil
        converter = nil
        converterInputFormat = nil
        manuallyMixInputToMono = false
        onLevel = nil
        lock.unlock()
        activeContinuation?.finish()
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func consume(
        _ buffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        generation: UInt64
    ) {
        lock.lock()
        let recording = isRecording && recordingGeneration == generation
        let converter = self.converter
        let monoFormat = converterInputFormat
        let mixToMono = manuallyMixInputToMono
        lock.unlock()
        guard recording, let converter else { return }

        let converterInput = preparedConverterInputBuffer(
            from: buffer,
            mixToMono: mixToMono,
            monoFormat: monoFormat
        ) ?? buffer
        let ratio = targetFormat.sampleRate / converterInput.format.sampleRate
        let capacity = AVAudioFrameCount(Double(converterInput.frameLength) * ratio + 1_024)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        let provider = AudioConverterInputProvider(buffer: converterInput)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            provider.provide(outStatus: inputStatus)
        }
        guard status != .error, let channel = output.floatChannelData?.pointee else { return }

        let frameCount = Int(output.frameLength)
        guard frameCount > 0 else { return }
        let converted = Array(UnsafeBufferPointer(start: channel, count: frameCount))
        let level = Self.normalizedLevel(converted)

        lock.lock()
        guard isRecording, recordingGeneration == generation else {
            lock.unlock()
            return
        }
        let levelHandler = onLevel
        let activeContinuation = continuation
        lock.unlock()
        activeContinuation?.yield(converted)
        levelHandler?(level)
    }

    private func converterSourceFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
        guard inputFormat.channelCount > 1,
              let mono = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: inputFormat.sampleRate,
                  channels: 1,
                  interleaved: false
              ) else { return inputFormat }
        return mono
    }

    private func preparedConverterInputBuffer(
        from buffer: AVAudioPCMBuffer,
        mixToMono: Bool,
        monoFormat: AVAudioFormat?
    ) -> AVAudioPCMBuffer? {
        guard mixToMono else { return buffer }
        guard let monoFormat, let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 1, frameCount > 0,
              let output = AVAudioPCMBuffer(
                  pcmFormat: monoFormat,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ), let mono = output.floatChannelData?.pointee else { return nil }

        for frame in 0..<frameCount {
            var mixed: Float = 0
            for channel in 0..<channelCount { mixed += channels[channel][frame] }
            mono[frame] = mixed / Float(channelCount)
        }
        output.frameLength = AVAudioFrameCount(frameCount)
        return output
    }

    nonisolated static func normalizedLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = sqrt(sum / Float(samples.count))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 55) / 45, 0), 1)
    }
}

final class AudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provide(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !didProvideBuffer else {
            // `.endOfStream` permanently closes a reusable AVAudioConverter;
            // `.noDataNow` ends only this tap callback's conversion pass.
            outStatus.pointee = .noDataNow
            return nil
        }
        didProvideBuffer = true
        outStatus.pointee = .haveData
        return buffer
    }
}
