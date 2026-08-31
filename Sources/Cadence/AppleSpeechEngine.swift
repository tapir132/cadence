@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

struct SpeechUpdate: Sendable {
    let text: String
    let isFinal: Bool
}

enum SpeechEngineError: LocalizedError {
    case unavailable
    case permissions
    case noInput

    var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition is unavailable for the selected language."
        case .permissions: "Microphone and Speech Recognition access are required."
        case .noInput: "No microphone input format is available."
        }
    }
}

@MainActor
final class AppleSpeechEngine {
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    static var microphoneAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var speechAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// Speech invokes its authorization callback on an arbitrary queue. This
    /// method must remain nonisolated so Swift does not attach a main-actor
    /// executor precondition to that system-owned callback.
    nonisolated static func requestPermissions() async -> Bool {
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        return microphone && speech
    }

    func start(
        contextualStrings: [String],
        requiresOnDeviceRecognition: Bool,
        onUpdate: @escaping @Sendable (SpeechUpdate) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async throws {
        guard Self.microphoneAuthorized, Self.speechAuthorized else { throw SpeechEngineError.permissions }
        guard let recognizer, recognizer.isAvailable else { throw SpeechEngineError.unavailable }

        cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = Array(contextualStrings.prefix(100))
        if requiresOnDeviceRecognition, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechEngineError.noInput }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            onLevel(Self.normalizedLevel(buffer))
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                onUpdate(SpeechUpdate(text: result.bestTranscription.formattedString, isFinal: result.isFinal))
            }
            if error != nil {
                Task { @MainActor in self?.stopAudioEngine() }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func finish() {
        stopAudioEngine()
        recognitionRequest?.endAudio()
    }

    func cancel() {
        stopAudioEngine()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    nonisolated private static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?.pointee else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count { sum += channel[index] * channel[index] }
        let rms = sqrt(sum / Float(count))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 55) / 45, 0), 1)
    }
}
