import Testing
@testable import Cadence

@Test func liveEmitterTypesOnlyCompleteWords() throws {
    var emitter = LiveTranscriptEmitter()

    #expect(try emitter.consume("Dict")?.insertion == "")
    #expect(try emitter.consume("Dictation is")?.insertion == "Dictation")
    #expect(try emitter.consume("Dictation is now")?.insertion == " is")
    #expect(try emitter.consume("Dictation is now live")?.insertion == " now")

    let possibleFinal = try emitter.finalize("Dictation is now live", continuesAfterPause: false)
    let final = try #require(possibleFinal)
    #expect(final.insertion == " live.")
    #expect(final.transcript == "Dictation is now live.")
}

@Test func pauseFlushesTailAndNextSentenceKeepsTyping() throws {
    var emitter = LiveTranscriptEmitter()
    var inserted = ""

    inserted += try emitter.consume("The first")?.insertion ?? ""
    inserted += try emitter.consume("The first sentence")?.insertion ?? ""
    let possibleFirstFinal = try emitter.finalize("The first sentence", continuesAfterPause: true)
    let firstFinal = try #require(possibleFirstFinal)
    inserted += firstFinal.insertion
    #expect(inserted == "The first sentence.")
    #expect(firstFinal.sentenceFinal)

    inserted += try emitter.consume("The next")?.insertion ?? ""
    #expect(inserted == "The first sentence. The")
    let possibleSecondFinal = try emitter.finalize("The next sentence", continuesAfterPause: false)
    let secondFinal = try #require(possibleSecondFinal)
    inserted += secondFinal.insertion

    #expect(inserted == "The first sentence. The next sentence.")
    #expect(secondFinal.transcript == inserted)
}

@Test func terminalPunctuationRemainsProvisionalUntilFinalization() throws {
    var emitter = LiveTranscriptEmitter()
    #expect(try emitter.consume("Really")?.insertion == "")
    #expect(try emitter.consume("Really?")?.insertion == "")
    let final = try emitter.finalize("Really?", continuesAfterPause: false)
    #expect(final?.insertion == "Really?")
}

@Test func pauseNormalizesSoftOrMissingPunctuation() {
    #expect(LiveTranscriptEmitter.ensureSentencePunctuation("A statement") == "A statement.")
    #expect(LiveTranscriptEmitter.ensureSentencePunctuation("A clause,") == "A clause.")
    #expect(LiveTranscriptEmitter.ensureSentencePunctuation("A question?") == "A question?")
    #expect(LiveTranscriptEmitter.ensureSentencePunctuation("He said \"hello\"") == "He said \"hello.\"")
}

@Test func emitterRejectsAnyRevisionToAlreadyVisibleStreamingText() throws {
    var emitter = LiveTranscriptEmitter()
    _ = try emitter.consume("We write essays")

    #expect(throws: LiveTranscriptError.self) {
        try emitter.consume("We edit essays")
    }
}

@Test func modelMayWithdrawTheUncommittedTailShownInThePreview() throws {
    var emitter = LiveTranscriptEmitter()
    var inserted = ""

    inserted += try emitter.consume("Version this as like a like 0.")?.insertion ?? ""
    let revision = try emitter.consume("Version this as like a like")
    #expect(revision?.insertion == "")
    #expect(revision?.transcript == "Version this as like a like")

    inserted += try emitter.finalize(
        "Version this as like a like 0.2",
        continuesAfterPause: false
    )?.insertion ?? ""
    #expect(inserted == "Version this as like a like 0.2.")
}
