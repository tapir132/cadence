import Foundation
import Testing
@testable import Cadence

/// Arithmetic fixtures only: no device access, files, speech synthesis, or playback.
@Suite struct MeetingEchoCancellationTests {
    @Test func delayedSpeakerCopyIsCancelledAndDoubleTalkKeepsTheLocalSignal() throws {
        let kernel = try MeetingEchoKernel()
        let count = 16_000 * 8
        let playback = signal(count: count, seed: 47, amplitude: 0.3)
        let local = signal(count: count, seed: 913, amplitude: 0.15)
        let delay = 640
        var input: [Float] = []
        var output: [Float] = []
        for start in stride(from: 0, to: count, by: MeetingEchoKernel.frameSize) {
            let mic: [Float] = (start..<start + MeetingEchoKernel.frameSize).map { i in
                let echo = i >= delay ? playback[i - delay] * 0.55 : 0
                let reflection = i >= delay + 173 ? playback[i - delay - 173] * 0.12 : 0
                return echo + reflection + (i >= 16_000 * 6 ? local[i] : 0)
            }
            input += mic
            output += kernel.process(microphone: mic, playback: Array(playback[start..<start + MeetingEchoKernel.frameSize]))
        }
        let echoWindow = 16_000 * 4..<16_000 * 6
        let echoRatio = energy(Array(output[echoWindow])) / energy(Array(input[echoWindow]))
        #expect(echoRatio < 0.01) // At least 20 dB reduction after adaptation.
        let localWindow = 16_000 * 7..<count
        let residual = localWindow.map { output[$0] - local[$0] }
        let localError = energy(residual) / energy(Array(local[localWindow]))
        #expect(localError < 0.15) // Muting the mic would fail with an error of 1.
        #expect(output.allSatisfy { $0.isFinite })
        print("Echo numeric fixture: echo energy ratio=\(echoRatio), double-talk error=\(localError)")
    }

    @Test func playbackHistoryUsesCaptureTimeAndRejectsMissingReference() {
        var history = MeetingPlaybackHistory()
        let firstReset = history.append(CapturedAudioChunk(samples: [0, 1, 2, 3], startTime: 10))
        let secondReset = history.append(CapturedAudioChunk(samples: [4, 5, 6, 7], startTime: 10 + 4.0 / 16_000))
        #expect(!firstReset && !secondReset)
        #expect(history.samples(at: 10 + 2.5 / 16_000, count: 1)?.first == 2.5)
        #expect(history.samples(at: 10 + 2.0 / 16_000, count: 5) == [2, 3, 4, 5, 6])
        #expect(history.samples(at: 9, count: 1) == nil)
        #expect(history.samples(at: 11, count: 1) == nil)
        let gapReset = history.append(CapturedAudioChunk(samples: [8, 9], startTime: 12))
        #expect(gapReset)
        #expect(history.samples(at: 10, count: 1) == nil)
        _ = history.append(CapturedAudioChunk(samples: Array(repeating: 0, count: 40_000), startTime: 13))
        #expect(history.sampleCount <= MeetingPlaybackHistory.maximumSamples)
    }

    @Test func differentlySizedCaptureCallbacksCancelEchoAndPreserveTimeline() throws {
        let buffer = try MeetingEchoBuffer()
        let count = 16_000 * 8
        let playback = signal(count: count + 1_280, seed: 72, amplitude: 0.3)
        let local = signal(count: count, seed: 731, amplitude: 0.15)
        let mic: [Float] = (0..<count).map { i in
            let echo: Float = i >= 480 ? playback[i - 480] * 0.5 : 0
            let near: Float = i >= 96_000 ? local[i] : 0
            return echo + near
        }
        let epoch = 40_000.1234
        var events: [(arrival: Double, playback: Bool, start: Int, end: Int)] = []
        for start in stride(from: 0, to: playback.count, by: 320) {
            let end = min(start + 320, playback.count)
            events.append((Double(end) / 16_000 + 0.012, true, start, end))
        }
        for start in stride(from: 0, to: count, by: 1_280) {
            let end = min(start + 1_280, count)
            events.append((Double(end) / 16_000, false, start, end))
        }
        var chunks: [CapturedAudioChunk] = []
        for event in events.sorted(by: { $0.arrival < $1.arrival }) {
            let chunk = CapturedAudioChunk(
                samples: Array((event.playback ? playback : mic)[event.start..<event.end]),
                startTime: epoch + Double(event.start) / 16_000
            )
            if event.playback {
                buffer.appendPlayback(chunk)
                chunks += buffer.drain(now: event.arrival)
            } else {
                chunks += buffer.appendMicrophone(chunk, now: event.arrival)
            }
        }
        buffer.endPlayback()
        chunks += buffer.drain(now: 9, finishing: true)
        let output = chunks.flatMap(\.samples)
        #expect(output.count == count)
        for (index, chunk) in chunks.enumerated() {
            #expect(abs(chunk.startTime - epoch - Double(index * 256) / 16_000) < 0.000_001)
        }
        let echoWindow = 64_000..<96_000
        let echoRatio = energy(Array(output[echoWindow])) / energy(Array(mic[echoWindow]))
        #expect(echoRatio < 0.01)
        let localWindow = 112_000..<count
        let localError = energy(localWindow.map { output[$0] - local[$0] }) / energy(Array(local[localWindow]))
        #expect(localError < 0.15)
        print("Buffered echo fixture: echo energy ratio=\(echoRatio), double-talk error=\(localError)")
    }

    @Test func stalledPlaybackDoesNotHoldOrEraseMicAndStopDrainsTheTail() throws {
        let buffer = try MeetingEchoBuffer()
        let mic = CapturedAudioChunk(samples: Array(repeating: 0.25, count: 265), startTime: 4)
        #expect(buffer.appendMicrophone(mic, now: 10).isEmpty)
        #expect(buffer.drain(now: 10.1).isEmpty)
        var output = buffer.drain(now: 10.21)
        output += buffer.drain(now: 10.21, finishing: true)
        #expect(output.flatMap(\.samples) == mic.samples)
        #expect(output.first?.startTime == 4)
        #expect(output.last?.startTime == 4.016)
    }

    @Test func referenceArrivingAfterMicIsMatchedBeforeItsWaitExpires() throws {
        let buffer = try MeetingEchoBuffer()
        let mic = CapturedAudioChunk(samples: Array(repeating: 0, count: 256), startTime: 1)
        #expect(buffer.appendMicrophone(mic, now: 10).isEmpty)
        buffer.appendPlayback(CapturedAudioChunk(samples: Array(repeating: 0, count: 1_024), startTime: 1))
        let output = buffer.drain(now: 10.02)
        #expect(output.flatMap(\.samples).count == 256)
        #expect(output.first?.startTime == 1)
    }

    @Test func microphoneDiscontinuityDoesNotJoinOldSamplesToTheNewClock() throws {
        let buffer = try MeetingEchoBuffer()
        buffer.endPlayback()
        #expect(buffer.appendMicrophone(CapturedAudioChunk(samples: [0.1, 0.2], startTime: 1), now: 1).isEmpty)
        let old = buffer.appendMicrophone(CapturedAudioChunk(samples: [0.3], startTime: 4), now: 4)
        #expect(old.first?.samples == [0.1, 0.2])
        #expect(old.first?.startTime == 1)
        let final = buffer.drain(now: 4, finishing: true)
        #expect(final.first?.samples == [0.3])
        #expect(final.first?.startTime == 4)
    }

    private func signal(count: Int, seed: UInt64, amplitude: Float) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * amplitude
        }
    }

    private func energy(_ values: [Float]) -> Float { values.reduce(0) { $0 + $1 * $1 } }
}
