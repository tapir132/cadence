import AVFoundation
import Speech
import Testing
@testable import Cadence

/// The audio tap runs on AVAudio's realtime queue. If it ever inherits the
/// engine's main-actor isolation again, invoking it here traps the process.
@Test func audioTapRunsOffTheMainActor() async throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    nonisolated(unsafe) let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
    buffer.frameLength = 1024

    let level: Float = await withCheckedContinuation { continuation in
        nonisolated(unsafe) let tap = AppleSpeechEngine.audioTap(request: SFSpeechAudioBufferRecognitionRequest()) {
            continuation.resume(returning: $0)
        }
        DispatchQueue.global(qos: .userInteractive).async {
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
        }
    }

    #expect((0...1).contains(level))
}
