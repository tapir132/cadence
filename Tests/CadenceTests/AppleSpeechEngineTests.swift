@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import Cadence

@Test func audioLevelsAreNormalizedAndBounded() {
    #expect(AudioCaptureEngine.normalizedLevel([]) == 0)
    #expect(AudioCaptureEngine.normalizedLevel(Array(repeating: 0, count: 128)) == 0)

    let speechLevel = AudioCaptureEngine.normalizedLevel(Array(repeating: 0.1, count: 128))
    #expect(speechLevel > 0)
    #expect(speechLevel < 1)
    #expect(AudioCaptureEngine.normalizedLevel(Array(repeating: 10, count: 128)) == 1)
}

/// Reusing one AVAudioConverter must keep producing samples after many audio
/// tap callbacks. Returning `.endOfStream` from any callback makes later
/// buffers silently empty, which presents as dictation stopping after a pause.
@Test func audioConverterAcceptsConsecutiveTapBuffers() throws {
    let source = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    ))
    let target = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ))
    let converter = try #require(AVAudioConverter(from: source, to: target))

    var totalFrames = 0
    for callback in 0..<60 {
        let input = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4_800))
        input.frameLength = 4_800
        let channel = try #require(input.floatChannelData?.pointee)
        for frame in 0..<Int(input.frameLength) {
            channel[frame] = sin(Float(frame + callback) * 0.04) * 0.1
        }

        let output = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 2_624))
        let provider = AudioConverterInputProvider(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            provider.provide(outStatus: inputStatus)
        }

        #expect(status != .error)
        #expect(conversionError == nil)
        #expect(output.frameLength > 0, "Callback \(callback) produced no samples")
        totalFrames += Int(output.frameLength)
    }

    #expect(totalFrames > 90_000)
}

/// Opt-in because it downloads the production streaming ASR and VAD models.
/// This drives the real Cadence pipeline in microphone-sized chunks. Sentence
/// one must be emitted word by word, including its tail and period, before any
/// audio from sentence two is supplied; the held session must then continue.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CADENCE_RUN_STREAMING_MODEL_TEST"] == "1"))
func streamingModelCommitsSentenceTailDuringPauseAndContinues() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cadence-streaming-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstURL = directory.appendingPathComponent("first.aiff")
    let finalURL = directory.appendingPathComponent("final.aiff")
    try synthesize("These are the first words of the dictation.", to: firstURL)
    try synthesize("These are the final words after the pause.", to: finalURL)

    let converter = AudioConverter()
    let first = try converter.resampleAudioFile(firstURL)
    let finalSamples = try converter.resampleAudioFile(finalURL)
    let initialSilence = Array(repeating: Float.zero, count: 16_000)
    let silence = Array(repeating: Float.zero, count: 32_000)

    let transcriber = LiveSpeechTranscriber()
    try await transcriber.prepare { _ in }
    let (audio, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
    let recorder = LiveUpdateRecorder()
    let transcription = Task {
        try await transcriber.transcribe(audio) { update in recorder.record(update) }
    }

    yieldSamples(initialSilence + first + silence, to: continuation)
    let firstPause = try #require(await recorder.waitForSentenceFinal(count: 1))
    let duringPause = firstPause.transcript.lowercased()
    #expect(duringPause.contains("first words"), "The first sentence was not live yet: \(duringPause)")
    #expect(duringPause.hasSuffix("dictation."), "Its tail and period were not inserted during the pause: \(duringPause)")
    #expect(recorder.insertedText.lowercased().hasSuffix("dictation."))

    // Only now does later audio enter the pipeline. Repeated rollovers cover
    // the original long-held-session failure, not only one lucky pause.
    let laterSentenceCount = 5
    for sentence in 1...laterSentenceCount {
        yieldSamples(finalSamples + silence, to: continuation)
        _ = try #require(await recorder.waitForSentenceFinal(count: sentence + 1))
    }
    continuation.finish()
    let finalTranscript = try await transcription.value.lowercased()
    #expect(finalTranscript.hasPrefix("these are the first words"), "Leading silence invented text: \(finalTranscript)")
    #expect(finalTranscript.contains("first words"))
    #expect(finalTranscript.contains("final words"))
    #expect(finalTranscript.components(separatedBy: "final words").count - 1 == laterSentenceCount)
    #expect(finalTranscript.hasSuffix("pause."), "The final streamed tail was lost: \(finalTranscript)")
    #expect(recorder.insertedText.lowercased() == finalTranscript)

    let updates = recorder.snapshot()
    #expect(updates.count > 4, "Expected multiple visible live updates, received \(updates.count)")
    for (previous, next) in zip(updates, updates.dropFirst()) {
        #expect(
            next.transcript.hasPrefix(previous.transcript),
            "Streaming output revised already-visible text: \(previous.transcript) -> \(next.transcript)"
        )
    }
}

private final class LiveUpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [LiveTranscriptUpdate] = []
    private var inserted = ""

    func record(_ update: LiveTranscriptUpdate) {
        lock.lock()
        updates.append(update)
        inserted += update.insertion
        lock.unlock()
    }

    var insertedText: String {
        lock.lock()
        defer { lock.unlock() }
        return inserted
    }

    func waitForSentenceFinal(count: Int, timeout: Duration = .seconds(15)) async -> LiveTranscriptUpdate? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let match = lock.withLock {
                let finals = updates.filter(\.sentenceFinal)
                return finals.count >= count ? finals[count - 1] : nil
            }
            if let match { return match }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func snapshot() -> [LiveTranscriptUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}

private func yieldSamples(
    _ samples: [Float],
    to continuation: AsyncStream<[Float]>.Continuation
) {
    let microphoneSizedChunk = 1_365
    for start in stride(from: 0, to: samples.count, by: microphoneSizedChunk) {
        let end = min(start + microphoneSizedChunk, samples.count)
        continuation.yield(Array(samples[start..<end]))
    }
}

private func synthesize(_ text: String, to url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-r", "175", "-o", url.path, text]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}
