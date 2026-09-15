@preconcurrency import AVFoundation
import Foundation

/// Opt-in shipping-bundle check. Reads live audio buffers without recognizing,
/// playing, or saving audio. This validates the real capture timestamps and
/// stream completion separately from deterministic ASR fixture tests.
enum MeetingCaptureSmokeTest {
    static func run() async -> Bool {
        guard AudioCaptureEngine.microphoneAuthorized else {
            print("capture: microphone permission is required")
            return false
        }
        do {
            for round in 1...2 {
                let source = MeetingAudioSource()
                let audio = try await Task.detached { try source.start { _ in } }.value
                defer { source.finish() }
                let microphone = Task { await inspect(audio.microphone) }
                let system = Task { await inspect(audio.system) }
                try await Task.sleep(for: .seconds(2))
                source.finish()
                let mic = await microphone.value
                let sys = await system.value
                print("capture \(round): mic samples=\(mic.samples), valid timestamps=\(mic.valid)")
                print("capture \(round): system samples=\(sys.samples), valid timestamps=\(sys.valid)")
                guard mic.samples > 16_000, mic.valid else { return false }
                if ProcessInfo.processInfo.environment["CADENCE_NOTES_MICROPHONE_ONLY"] != "1" {
                    guard source.systemAudioError == nil, sys.samples > 16_000, sys.valid else { return false }
                }
            }
            // The original untimestamped API still supplies normal dictation.
            let hardware = AVAudioEngine()
            let engine = AudioCaptureEngine(audioEngine: hardware)
            let startedAt = ContinuousClock.now
            let audio = try engine.start { _ in }
            defer { engine.finish() }
            let reader = Task {
                var count = 0
                var recoveredCount = 0
                for await samples in audio {
                    if count == 0 { print("capture: first dictation buffer after \(startedAt.duration(to: .now))") }
                    count += samples.count
                    if startedAt.duration(to: .now) > .seconds(3) { recoveredCount += samples.count }
                }
                return (count, recoveredCount)
            }
            try await Task.sleep(for: .seconds(2))
            // Reproduce AVAudioEngine's documented configuration-change
            // behavior with a real stopped engine and a real notification.
            hardware.stop()
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: hardware)
            try await Task.sleep(for: .seconds(4))
            engine.finish()
            let samples = await reader.value
            print("capture: dictation samples=\(samples.0), samples after recovery=\(samples.1)")
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: hardware)
            try await Task.sleep(for: .milliseconds(200))
            print("capture: engine remains stopped=\(!hardware.isRunning)")
            return samples.0 > 16_000 && samples.1 > 16_000 && !hardware.isRunning
        } catch {
            print("capture failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func inspect(_ audio: AsyncStream<CapturedAudioChunk>) async -> (samples: Int, valid: Bool) {
        var count = 0
        var previous = -Double.infinity
        var valid = true
        for await chunk in audio {
            count += chunk.samples.count
            let now = ProcessInfo.processInfo.systemUptime
            valid = valid && chunk.startTime.isFinite && chunk.startTime >= previous
                && abs(now - chunk.startTime) < 5 && chunk.samples.allSatisfy(\.isFinite)
            previous = chunk.startTime
        }
        return (count, valid)
    }
}
