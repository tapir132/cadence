import CSpeexDSP
import Foundation

/// DSP only: this type never opens a device or changes the Mac's playback.
/// Each recording owns one state, with a 200 ms adaptive echo tail.
final class MeetingEchoKernel {
    static let frameSize = 256
    static let sampleRate = 16_000.0
    private let state: OpaquePointer

    init() throws {
        guard let state = speex_echo_state_init(Int32(Self.frameSize), 3_200) else {
            throw SpeechEngineError.modelUnavailable("Speaker echo cancellation could not start.")
        }
        self.state = state
        var rate: Int32 = 16_000
        speex_echo_ctl(state, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
    }

    deinit { speex_echo_state_destroy(state) }
    func reset() { speex_echo_state_reset(state) }

    func process(microphone: [Float], playback: [Float]) -> [Float] {
        precondition(microphone.count == Self.frameSize && playback.count == Self.frameSize)
        let mic = microphone.map(Self.pcm16)
        let reference = playback.map(Self.pcm16)
        var output = [Int16](repeating: 0, count: Self.frameSize)
        speex_echo_cancellation(state, mic, reference, &output)
        return output.map { Float($0) / 32_768 }
    }

    private static func pcm16(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        return Int16((min(max(sample, -1), 1) * 32_767).rounded())
    }
}

/// Playback history uses capture timestamps, not callback arrival or decoder
/// timing. It also resamples small device-clock offsets onto the mic clock.
struct MeetingPlaybackHistory {
    private var chunks: [CapturedAudioChunk] = []
    private(set) var sampleCount = 0
    private static let rate = MeetingEchoKernel.sampleRate
    static let maximumSamples = 32_000

    /// Returns true when a discontinuity invalidated the adaptive filter.
    mutating func append(_ chunk: CapturedAudioChunk) -> Bool {
        guard !chunk.samples.isEmpty, chunk.startTime.isFinite else { return false }
        var discontinuity = false
        if let last = chunks.last {
            let expected = last.startTime + Double(last.samples.count) / Self.rate
            if abs(chunk.startTime - expected) > 0.04 {
                chunks.removeAll(keepingCapacity: true)
                sampleCount = 0
                discontinuity = true
            }
        }
        // Keep memory bounded even for an unexpectedly large producer buffer.
        let samples = Array(chunk.samples.suffix(Self.maximumSamples))
        let start = chunk.startTime + Double(chunk.samples.count - samples.count) / Self.rate
        chunks.append(CapturedAudioChunk(samples: samples, startTime: start))
        sampleCount += samples.count
        while sampleCount > Self.maximumSamples, chunks.count > 1 {
            sampleCount -= chunks.removeFirst().samples.count
        }
        return discontinuity
    }

    func samples(at startTime: TimeInterval, count: Int) -> [Float]? {
        guard count > 0, let first = chunks.first, startTime >= first.startTime - 0.5 / Self.rate else { return nil }
        var index = 0
        var output: [Float] = []
        output.reserveCapacity(count)
        for offset in 0..<count {
            let time = startTime + Double(offset) / Self.rate
            while index < chunks.count,
                  time >= chunks[index].startTime + Double(chunks[index].samples.count) / Self.rate - 0.5 / Self.rate {
                index += 1
            }
            guard index < chunks.count else { return nil }
            let chunk = chunks[index]
            let position = (time - chunk.startTime) * Self.rate
            guard position >= -0.5, position < Double(chunk.samples.count) else { return nil }
            let lower = min(max(Int(floor(position)), 0), chunk.samples.count - 1)
            let upper = min(lower + 1, chunk.samples.count - 1)
            let fraction = Float(max(position - Double(lower), 0))
            let value = chunk.samples[lower] + (chunk.samples[upper] - chunk.samples[lower]) * fraction
            guard value.isFinite else { return nil }
            output.append(value)
        }
        return output
    }
}

/// Pure buffered processing, separated from scheduling for deterministic tests.
/// A short look-ahead puts the reference ahead of the acoustic echo, even when
/// the two converters have slightly different latencies. Missing reference
/// never mutes or indefinitely holds the local speaker.
final class MeetingEchoBuffer {
    static let referenceLookAhead: TimeInterval = 0.032
    static let maximumWait: TimeInterval = 0.2
    private let kernel: MeetingEchoKernel
    private var history = MeetingPlaybackHistory()
    private var pending: [Float] = []
    private var startTime: TimeInterval?
    private struct Arrival {
        var remaining: Int
        let time: TimeInterval
    }
    private var arrivals: [Arrival] = []
    private var lastMicrophoneEnd: TimeInterval?
    private var playbackEnded = false

    init() throws { kernel = try MeetingEchoKernel() }

    func appendPlayback(_ chunk: CapturedAudioChunk) {
        if history.append(chunk) { kernel.reset() }
    }

    func endPlayback() { playbackEnded = true }

    func appendMicrophone(_ chunk: CapturedAudioChunk, now: TimeInterval) -> [CapturedAudioChunk] {
        guard chunk.startTime.isFinite, !chunk.samples.isEmpty else { return [] }
        var flushed: [CapturedAudioChunk] = []
        if let expected = lastMicrophoneEnd {
            if abs(chunk.startTime - expected) > 0.04 {
                flushed = drain(now: now, finishing: true)
                kernel.reset()
            }
        }
        lastMicrophoneEnd = chunk.startTime + Double(chunk.samples.count) / MeetingEchoKernel.sampleRate
        if pending.isEmpty {
            startTime = chunk.startTime
        }
        pending.append(contentsOf: chunk.samples.map { $0.isFinite ? $0 : 0 })
        arrivals.append(Arrival(remaining: chunk.samples.count, time: now))
        return flushed + drain(now: now)
    }

    func drain(now: TimeInterval, finishing: Bool = false) -> [CapturedAudioChunk] {
        var result: [CapturedAudioChunk] = []
        while let start = startTime, pending.count >= MeetingEchoKernel.frameSize || (finishing && !pending.isEmpty) {
            let count = min(pending.count, MeetingEchoKernel.frameSize)
            let mic = Array(pending.prefix(count))
            let reference = history.samples(at: start + Self.referenceLookAhead, count: count)
            if reference == nil, !finishing, !playbackEnded,
               let arrival = arrivals.first, now - arrival.time < Self.maximumWait { break }
            let output: [Float]
            if let reference {
                let padding = [Float](repeating: 0, count: MeetingEchoKernel.frameSize - count)
                output = Array(kernel.process(microphone: mic + padding, playback: reference + padding).prefix(count))
            } else {
                kernel.reset()
                output = mic
            }
            result.append(CapturedAudioChunk(samples: output, startTime: start))
            pending.removeFirst(count)
            var consumed = count
            while consumed > 0, !arrivals.isEmpty {
                let used = min(consumed, arrivals[0].remaining)
                arrivals[0].remaining -= used
                consumed -= used
                if arrivals[0].remaining == 0 { arrivals.removeFirst() }
            }
            startTime = pending.isEmpty ? nil : start + Double(count) / MeetingEchoKernel.sampleRate
        }
        return result
    }
}

/// Both producers enqueue quickly; filtering runs off the capture callbacks.
/// A timer releases mic frames after 200 ms if the playback tap stalls.
final class MeetingEchoStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.cadence.meeting-echo", qos: .userInitiated)
    private let buffer: MeetingEchoBuffer
    private let output: AsyncStream<CapturedAudioChunk>.Continuation
    private let onLevel: @Sendable (Float) -> Void
    private let timer: DispatchSourceTimer
    private var finished = false

    init(output: AsyncStream<CapturedAudioChunk>.Continuation, onLevel: @escaping @Sendable (Float) -> Void) throws {
        self.output = output
        self.onLevel = onLevel
        buffer = try MeetingEchoBuffer()
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            self.emit(self.buffer.drain(now: ProcessInfo.processInfo.systemUptime))
        }
        timer.resume()
    }

    func appendPlayback(_ chunk: CapturedAudioChunk) {
        queue.async { [self] in
            guard !finished else { return }
            buffer.appendPlayback(chunk)
            emit(buffer.drain(now: ProcessInfo.processInfo.systemUptime))
        }
    }

    func appendMicrophone(_ chunk: CapturedAudioChunk) {
        queue.async { [self] in
            guard !finished else { return }
            emit(buffer.appendMicrophone(chunk, now: ProcessInfo.processInfo.systemUptime))
        }
    }

    func endPlayback() {
        queue.async { [self] in
            guard !finished else { return }
            buffer.endPlayback()
            emit(buffer.drain(now: ProcessInfo.processInfo.systemUptime))
        }
    }

    func finish() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            timer.cancel()
            emit(buffer.drain(now: ProcessInfo.processInfo.systemUptime, finishing: true))
            output.finish()
        }
    }

    private func emit(_ chunks: [CapturedAudioChunk]) {
        for chunk in chunks { output.yield(chunk) }
        if !chunks.isEmpty { onLevel(AudioCaptureEngine.normalizedLevel(chunks.flatMap(\.samples))) }
    }

    deinit { timer.cancel(); output.finish() }
}
