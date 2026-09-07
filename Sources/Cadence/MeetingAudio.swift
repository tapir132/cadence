@preconcurrency import AVFoundation
import AppKit
import CoreAudio
import Foundation

enum MeetingSpeaker: String, Codable, Sendable {
    case you
    case them

    var title: String {
        switch self {
        case .you: "You"
        case .them: "Them"
        }
    }
}

struct MicrophoneUser: Equatable, Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
}

/// Which other processes are recording from a microphone right now. Core Audio
/// publishes one process object per audio client, so a call in Zoom, Teams, or
/// a browser tab shows up here the moment its microphone opens and disappears
/// when the call releases it. No Accessibility trust or window-title scraping.
enum MicrophoneUseMonitor {
    static func processesUsingMicrophone() -> [MicrophoneUser] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            guard CoreAudioProperty.uint32(object, kAudioProcessPropertyIsRunningInput) ?? 0 != 0 else { return nil }
            let pid = CoreAudioProperty.uint32(object, kAudioProcessPropertyPID).map { pid_t(bitPattern: $0) } ?? 0
            return MicrophoneUser(pid: pid, bundleIdentifier: CoreAudioProperty.string(object, kAudioProcessPropertyBundleID))
        }
    }

    /// The call worth offering notes for, ignoring Cadence itself.
    static func callCandidate(
        among users: [MicrophoneUser],
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> MicrophoneUser? {
        users.first { $0.pid != ownPID && $0.pid > 0 }
    }

    static func appName(for user: MicrophoneUser) -> String {
        NSRunningApplication(processIdentifier: user.pid)?.localizedName
            ?? user.bundleIdentifier?.split(separator: ".").last.map(String.init)
            ?? "An app"
    }
}

enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

enum SystemAudioTapError: LocalizedError {
    case status(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .status(step, status):
            "System audio capture failed while \(step) (OSStatus \(status)). Allow Cadence under System Settings → Privacy & Security → Screen & System Audio Recording."
        }
    }
}

/// Captures everything the Mac plays, except Cadence itself, through a Core
/// Audio process tap (macOS 14.2+). Unlike ScreenCaptureKit this needs only the
/// "System Audio Recording Only" grant, which macOS asks for on first use, and
/// no screen-recording permission. The tap is attached to a private aggregate
/// device so an IOProc can read it like a microphone.
final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.cadence.system-audio-tap")

    /// Delivers 16 kHz mono chunks to `onSamples` from the tap's own queue.
    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Cadence Notes"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw SystemAudioTapError.status("creating the tap", status) }

        var formatAddress = CoreAudioProperty.address(kAudioTapPropertyFormat)
        var streamDescription = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &streamDescription)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            stop()
            throw SystemAudioTapError.status("reading the tap format", status)
        }

        let system = AudioObjectID(kAudioObjectSystemObject)
        var outputAddress = CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(system, &outputAddress, 0, nil, &deviceSize, &outputDevice)
        guard status == noErr, let outputUID = CoreAudioProperty.string(outputDevice, kAudioDevicePropertyDeviceUID) else {
            stop()
            throw SystemAudioTapError.status("finding the output device", status)
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cadence Notes",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw SystemAudioTapError.status("creating the aggregate device", status)
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: tapFormat.sampleRate, channels: 1, interleaved: false
        ), let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            stop()
            throw SpeechEngineError.noInput
        }
        let channels = Int(tapFormat.channelCount)
        let interleaved = tapFormat.isInterleaved

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / (interleaved ? max(channels, 1) : 1)
            guard frames > 0, let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let out = mono.floatChannelData?.pointee else { return }
            mono.frameLength = AVAudioFrameCount(frames)
            if interleaved {
                let source = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += source[frame * channels + channel] }
                    out[frame] = sum / Float(channels)
                }
            } else {
                // Non-interleaved taps deliver one buffer per channel; average them.
                for frame in 0..<frames { out[frame] = 0 }
                var counted = 0
                for buffer in buffers {
                    guard let channelData = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    counted += 1
                    for frame in 0..<frames { out[frame] += channelData[frame] }
                }
                for frame in 0..<frames { out[frame] /= Float(max(counted, 1)) }
            }

            let ratio = targetFormat.sampleRate / monoFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(frames) * ratio + 1_024)
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            let provider = AudioConverterInputProvider(buffer: mono)
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, inputStatus in
                provider.provide(outStatus: inputStatus)
            }
            guard result != .error, let channel = output.floatChannelData?.pointee, output.frameLength > 0 else { return }
            onSamples(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
        }
        guard status == noErr else {
            stop()
            throw SystemAudioTapError.status("installing the audio callback", status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw SystemAudioTapError.status("starting capture", status)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}

/// Sums the microphone and the system tap into one 16 kHz stream for the
/// decoder and remembers which side has been louder lately, which is how a
/// finished phrase gets labeled You or Them.
/// ponytail: energy dominance, not diarization. Two decoders (one per source)
/// would label perfectly at twice the model memory.
struct MeetingAudioMixer: Sendable {
    static let frameSize = 1_600 // 100 ms at 16 kHz
    private static let maxBacklog = frameSize * 8

    private var microphone: [Float] = []
    private var system: [Float] = []
    private(set) var microphoneEnergy: Float = 0
    private(set) var systemEnergy: Float = 0

    var dominantSpeaker: MeetingSpeaker {
        systemEnergy > microphoneEnergy ? .them : .you
    }

    /// Returns any mixed frames that became complete after this push.
    mutating func push(_ source: MeetingSpeaker, _ samples: [Float]) -> [[Float]] {
        switch source {
        case .you: microphone.append(contentsOf: samples)
        case .them: system.append(contentsOf: samples)
        }
        var frames: [[Float]] = []
        while microphone.count >= Self.frameSize, system.count >= Self.frameSize {
            frames.append(mix(Array(microphone.prefix(Self.frameSize)), Array(system.prefix(Self.frameSize))))
            microphone.removeFirst(Self.frameSize)
            system.removeFirst(Self.frameSize)
        }
        // One side has gone quiet or missing (no tap permission, an unplugged
        // mic). Never hold the other side's speech hostage waiting for it.
        while microphone.count >= Self.maxBacklog, system.isEmpty {
            frames.append(mix(Array(microphone.prefix(Self.frameSize)), []))
            microphone.removeFirst(Self.frameSize)
        }
        while system.count >= Self.maxBacklog, microphone.isEmpty {
            frames.append(mix([], Array(system.prefix(Self.frameSize))))
            system.removeFirst(Self.frameSize)
        }
        return frames
    }

    private mutating func mix(_ mic: [Float], _ sys: [Float]) -> [Float] {
        let smoothing: Float = 0.6
        microphoneEnergy = microphoneEnergy * smoothing + Self.rms(mic) * (1 - smoothing)
        systemEnergy = systemEnergy * smoothing + Self.rms(sys) * (1 - smoothing)
        let count = max(mic.count, sys.count)
        var mixed = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let value = (index < mic.count ? mic[index] : 0) + (index < sys.count ? sys[index] : 0)
            mixed[index] = min(max(value, -1), 1)
        }
        return mixed
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return sqrt(sum / Float(samples.count))
    }
}

/// Runs the microphone engine and the system tap together and exposes one
/// ordered AsyncStream for `LiveSpeechTranscriber`, plus the live speaker guess.
final class MeetingAudioSource: @unchecked Sendable {
    private let microphone = AudioCaptureEngine()
    private let tap = SystemAudioTap()
    private let lock = NSLock()
    private var mixer = MeetingAudioMixer()
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var microphoneTask: Task<Void, Never>?
    private(set) var systemAudioError: Error?

    var dominantSpeaker: MeetingSpeaker {
        lock.lock()
        defer { lock.unlock() }
        return mixer.dominantSpeaker
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws -> AsyncStream<[Float]> {
        let microphoneStream = try microphone.start(onLevel: onLevel)
        var streamContinuation: AsyncStream<[Float]>.Continuation?
        let stream = AsyncStream<[Float]>(bufferingPolicy: .unbounded) { streamContinuation = $0 }
        lock.lock()
        continuation = streamContinuation
        lock.unlock()

        do {
            // Diagnostic: `CADENCE_NOTES_MICROPHONE_ONLY=1` skips the system tap
            // (and its one-time permission prompt) to exercise the rest alone.
            if ProcessInfo.processInfo.environment["CADENCE_NOTES_MICROPHONE_ONLY"] == "1" {
                throw SystemAudioTapError.status("skipped by CADENCE_NOTES_MICROPHONE_ONLY", 0)
            }
            try tap.start { [weak self] samples in self?.push(.them, samples) }
        } catch {
            systemAudioError = error
            NSLog("Cadence Notes is recording without system audio: %@", error.localizedDescription)
        }
        microphoneTask = Task { [weak self] in
            for await samples in microphoneStream { self?.push(.you, samples) }
            self?.finishStream()
        }
        return stream
    }

    func finish() {
        tap.stop()
        microphone.finish()
    }

    private func push(_ source: MeetingSpeaker, _ samples: [Float]) {
        lock.lock()
        let frames = mixer.push(source, samples)
        let active = continuation
        lock.unlock()
        for frame in frames { active?.yield(frame) }
    }

    private func finishStream() {
        lock.lock()
        let active = continuation
        continuation = nil
        lock.unlock()
        active?.finish()
    }
}
