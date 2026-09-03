import Foundation
import Testing
@testable import Cadence

@Test func speechModelsUseAStableApplicationSupportDirectory() {
    let applicationSupport = URL(fileURLWithPath: "/tmp/example/Library/Application Support")
    let store = SpeechModelStore(applicationSupportDirectory: applicationSupport)

    #expect(
        store.modelsDirectory.path
            == "/tmp/example/Library/Application Support/FluidAudio/Models"
    )
    #expect(!store.modelsDirectory.path.contains("Cadence.app"))
}

@Test func speechModelManifestIncludesBothRecognitionProfilesAndVad() {
    let applicationSupport = URL(fileURLWithPath: "/tmp/example/Library/Application Support")
    let store = SpeechModelStore(applicationSupportDirectory: applicationSupport)
    let relativePaths = Set(store.requiredArtifacts.map(\.relativePath))

    #expect(
        relativePaths.contains(
            "parakeet-unified-en-0.6b/parakeet_unified_encoder_streaming_70_2_2_int8.mlmodelc"
        )
    )
    #expect(
        relativePaths.contains(
            "parakeet-unified-en-0.6b/parakeet_unified_encoder_streaming_70_7_7_int8.mlmodelc"
        )
    )
    #expect(
        relativePaths.contains(
            "silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc"
        )
    )
}

@Test func completeSpeechModelsAreReusedButPartialDownloadsAreNot() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cadence-model-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = SpeechModelStore(applicationSupportDirectory: directory)
    #expect(!store.allRequiredModelsAreInstalled())

    for artifact in store.requiredArtifacts {
        let url = store.modelsDirectory.appendingPathComponent(artifact.relativePath)
        if artifact.isCompiledModel {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("compiled".utf8).write(to: url.appendingPathComponent("coremldata.bin"))
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("present".utf8).write(to: url)
        }
    }
    #expect(store.allRequiredModelsAreInstalled())

    let encoder = store.modelsDirectory.appendingPathComponent(
        "parakeet-unified-en-0.6b/parakeet_unified_encoder_streaming_70_7_7_int8.mlmodelc"
    )
    try Data("unfinished".utf8).write(to: encoder.appendingPathComponent("weights.partial"))
    #expect(!store.allRequiredModelsAreInstalled())
}
