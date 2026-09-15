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

    /// Apps whose open microphone means a call. Dictation tools such as Wispr
    /// Flow, voice memos, and unknown apps also open the microphone, so only
    /// these prefixes count. Browser helpers cover Meet, Zoom web, and Teams
    /// web; WebKit's GPU process is how Safari records.
    /// ponytail: static prefix list; add entries as people report missed apps.
    static let callApps: [(prefix: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.cisco.webex", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.google.Chrome", "Chrome"),
        ("com.apple.WebKit", "Safari"),
        ("com.apple.Safari", "Safari"),
        ("org.mozilla", "Firefox"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.brave.Browser", "Brave"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("com.whatsapp.WhatsApp", "WhatsApp"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("org.telegram.desktop", "Telegram"),
        ("ru.keepcoder.Telegram", "Telegram"),
        ("com.skype.skype", "Skype"),
        ("com.loom.desktop", "Loom"),
        ("com.gotomeeting", "GoTo"),
        ("com.logmein.GoToMeeting", "GoTo"),
        ("com.bluejeans", "BlueJeans"),
        ("com.amazon.Amazon-Chime", "Chime"),
        ("com.dialpad", "Dialpad"),
        ("com.ringcentral", "RingCentral"),
        ("com.whereby", "Whereby")
    ]

    /// The call worth offering notes for, ignoring Cadence itself and any
    /// microphone user that is not a known call app.
    static func callCandidate(
        among users: [MicrophoneUser],
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> MicrophoneUser? {
        users.first { $0.pid != ownPID && $0.pid > 0 && callApp(for: $0) != nil }
    }

    static func callApp(for user: MicrophoneUser) -> String? {
        guard let bundle = user.bundleIdentifier else { return nil }
        return callApps.first { bundle.hasPrefix($0.prefix) }?.name
    }

    static func appName(for user: MicrophoneUser) -> String {
        callApp(for: user) ?? "A call"
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

/// Captures everything the Mac plays through a Core
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
    func start(onSamples: @escaping @Sendable (CapturedAudioChunk) -> Void) throws {
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

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, inputTime, _, _ in
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
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            let timestamp = inputTime.pointee
            let startTime = timestamp.mFlags.contains(.hostTimeValid)
                ? AVAudioTime.seconds(forHostTime: timestamp.mHostTime)
                : ProcessInfo.processInfo.systemUptime - Double(samples.count) / 16_000
            onSamples(CapturedAudioChunk(samples: samples, startTime: startTime))
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

/// Each input retains its identity and timing through recognition. The mic's
/// echo stage has a bounded reference wait; missing system audio cannot stall it.
struct MeetingAudioStreams: Sendable {
    let microphone: AsyncStream<CapturedAudioChunk>
    let system: AsyncStream<CapturedAudioChunk>
}

final class MeetingAudioSource: @unchecked Sendable {
    private let microphone = AudioCaptureEngine()
    private let tap = SystemAudioTap()
    private var systemContinuation: AsyncStream<CapturedAudioChunk>.Continuation?
    private var microphoneForwarder: Task<Void, Never>?
    private var echoStream: MeetingEchoStream?
    private(set) var systemAudioError: Error?

    func start(onLevel: @escaping @Sendable (Float) -> Void) throws -> MeetingAudioStreams {
        systemAudioError = nil
        let (microphoneStream, micOutput) = AsyncStream<CapturedAudioChunk>.makeStream()
        let echo = try MeetingEchoStream(output: micOutput, onLevel: onLevel)
        echoStream = echo
        let rawMicrophone: AsyncStream<CapturedAudioChunk>
        do {
            rawMicrophone = try microphone.startTimestamped(onLevel: { _ in })
        } catch {
            echo.finish()
            echoStream = nil
            throw error
        }
        microphoneForwarder = Task.detached(priority: .userInitiated) {
            for await chunk in rawMicrophone { echo.appendMicrophone(chunk) }
            echo.finish()
        }
        let (system, continuation) = AsyncStream<CapturedAudioChunk>.makeStream(bufferingPolicy: .unbounded)
        systemContinuation = continuation
        do {
            // Diagnostic: skip the tap to exercise the microphone-only fallback.
            if ProcessInfo.processInfo.environment["CADENCE_NOTES_MICROPHONE_ONLY"] == "1" {
                throw SystemAudioTapError.status("skipped by CADENCE_NOTES_MICROPHONE_ONLY", 0)
            }
            try tap.start { chunk in
                echo.appendPlayback(chunk)
                continuation.yield(chunk)
            }
        } catch {
            echo.endPlayback()
            systemAudioError = error
            continuation.finish()
            NSLog("Cadence Notes is recording without system audio: %@", error.localizedDescription)
        }
        return MeetingAudioStreams(microphone: microphoneStream, system: system)
    }

    func finish() {
        tap.stop()
        echoStream?.endPlayback()
        systemContinuation?.finish()
        systemContinuation = nil
        microphone.finish()
        // The forwarder drains the microphone stream and then finishes echo
        // processing, including a final partial frame, before its output ends.
        microphoneForwarder = nil
        echoStream = nil
    }
}
