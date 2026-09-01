import Testing
@testable import Cadence

@Test func fillerCleanupRemovesOnlyStandaloneHesitations() {
    #expect(SpeechCleanupFormatter.format("Um, this is uh a test", enabled: true) == "This is a test")
    #expect(SpeechCleanupFormatter.format("I, um, think this works", enabled: true) == "I, think this works")
    #expect(SpeechCleanupFormatter.format("um uh erm okay", enabled: true) == "Okay")
    #expect(SpeechCleanupFormatter.format("the drummer and her friend", enabled: true) == "the drummer and her friend")
    #expect(SpeechCleanupFormatter.format("uh-huh, that works", enabled: true) == "uh-huh, that works")
    #expect(SpeechCleanupFormatter.format("um iPhone works", enabled: true) == "iPhone works")
}

@Test func fillerCleanupIsOptInAndSafeForLiveEmission() throws {
    #expect(SpeechCleanupFormatter.format("Um, keep this", enabled: false) == "Um, keep this")

    var emitter = LiveTranscriptEmitter(cleanupEnabled: true)
    var inserted = ""
    inserted += try emitter.consume("I um think")?.insertion ?? ""
    inserted += try emitter.consume("I um think this")?.insertion ?? ""
    inserted += try emitter.finalize("I um think this works", continuesAfterPause: false)?.insertion ?? ""
    #expect(inserted == "I think this works.")
}
