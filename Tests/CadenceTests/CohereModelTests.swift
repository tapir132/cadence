import FluidAudio
import Foundation
import Testing
@testable import Cadence

/// Opt-in: downloads the local model, never records or uploads audio.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CADENCE_RUN_COHERE_MODEL_TEST"] == "1"))
struct CohereModelIntegrationTests {
    @Test func localModelTranscribesSpeech() async throws {
        let store = SpeechModelStore()
        try await CohereMeetingModelStore(store: store).install { _ in }
        let modelsDirectory = store.modelsDirectory.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
        let models = try await CoherePipeline.loadModels(
            encoderDir: modelsDirectory, decoderDir: modelsDirectory, vocabDir: modelsDirectory,
            computeUnits: .cpuAndNeuralEngine
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-cohere-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("speech.aiff")
        let speech = Process()
        speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speech.arguments = ["-r", "175", "-o", url.path, "Can everyone see the dashboard? I will send the document tomorrow. The final word is pineapple."]
        try speech.run()
        speech.waitUntilExit()
        #expect(speech.terminationStatus == 0)
        let samples = try AudioConverter().resampleAudioFile(url)
        let pipeline = CoherePipeline()
        let result = try await pipeline.transcribe(audio: samples, models: models)
        print("Cohere probe: \(Double(samples.count) / 16_000)s audio, \(result.totalSeconds)s inference (encoder \(result.encoderSeconds)s, decoder \(result.decoderSeconds)s), \(result.tokenIds.count) tokens: \(result.text)")
        #expect(result.text.lowercased().contains("dashboard"))
        #expect(result.text.lowercased().contains("document tomorrow"))
        #expect(result.text.lowercased().contains("pineapple"))
        let warm = try await pipeline.transcribe(audio: samples, models: models)
        print("Cohere warm: \(warm.totalSeconds)s inference (encoder \(warm.encoderSeconds)s, decoder \(warm.decoderSeconds)s): \(warm.text)")
        #expect(warm.text == result.text)
    }
}
