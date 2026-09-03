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

@Test func aLowercaseDecoderRestartIsCapitalizedAfterSpokenPunctuation() throws {
    var emitter = LiveTranscriptEmitter(dictionaryTerms: ["macOS"])
    var inserted = ""

    // After punctuation the person asked for, a lowercase restart is a new
    // sentence. After an automatic period it is a continuation signal instead
    // (see the retraction tests below).
    inserted += try emitter.finalize(
        "The first sentence period",
        continuesAfterPause: true
    )?.insertion ?? ""
    inserted += try emitter.consume("the next thought continues")?.insertion ?? ""
    #expect(inserted == "The first sentence. The next thought")

    let next = try emitter.finalize(
        "the next thought continues question mark",
        continuesAfterPause: true
    )
    inserted += next?.insertion ?? ""
    inserted += try emitter.consume("macOS remains mixed case")?.insertion ?? ""
    #expect(inserted == "The first sentence. The next thought continues? macOS remains mixed")
}

@Test func grammaticalPauseFlushesTailWithoutInventingASentenceBoundary() throws {
    var emitter = LiveTranscriptEmitter()
    var inserted = ""

    inserted += try emitter.consume("Because my Apple")?.insertion ?? ""
    let pause = try emitter.flushPauseTail("Because my Apple dictation")
    inserted += pause?.insertion ?? ""
    #expect(inserted == "Because my Apple dictation")
    #expect(pause?.transcript == inserted)
    #expect(pause?.sentenceFinal == false)

    inserted += try emitter.consume(
        "Because my Apple dictation was messing"
    )?.insertion ?? ""
    let final = try emitter.finalize(
        "Because my Apple dictation was messing that up",
        continuesAfterPause: false
    )
    inserted += final?.insertion ?? ""

    #expect(inserted == "Because my Apple dictation was messing that up.")
    #expect(final?.transcript == inserted)
}

@Test func multiwordDictionaryPhraseStaysProvisionalUntilExactSpellingIsSafe() throws {
    var emitter = LiveTranscriptEmitter(dictionaryTerms: ["José Arcadio Buendía"])
    var inserted = ""

    inserted += try emitter.consume("I met Jose")?.insertion ?? ""
    inserted += try emitter.consume("I met Jose Arcadio")?.insertion ?? ""
    #expect(inserted == "I met")

    inserted += try emitter.consume("I met Jose Arcadio Buendia yesterday")?.insertion ?? ""
    #expect(inserted == "I met José Arcadio Buendía")
    inserted += try emitter.finalize(
        "I met Jose Arcadio Buendia yesterday",
        continuesAfterPause: false
    )?.insertion ?? ""
    #expect(inserted == "I met José Arcadio Buendía yesterday.")
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

@Test func finalizationRecognizesAQuestionTagDespiteModelPeriod() throws {
    let transcript = "You got to take the risk to have fun sometimes, you know."
    #expect(
        LiveTranscriptEmitter.ensureSentencePunctuation(transcript)
            == "You got to take the risk to have fun sometimes, you know?"
    )

    var emitter = LiveTranscriptEmitter()
    let update = try emitter.finalize(transcript, continuesAfterPause: false)
    #expect(update?.transcript == "You got to take the risk to have fun sometimes, you know?")
    #expect(
        LiveTranscriptEmitter.ensureSentencePunctuation(
            "You got to take the risk to have fun sometimes, you know,"
        ) == "You got to take the risk to have fun sometimes, you know?"
    )
    #expect(LiveTranscriptEmitter.ensureSentencePunctuation("I will let you know.") == "I will let you know.")
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

@Test func optionalTypingBufferAllowsARecentPrefixToChangeBeforeInsertion() throws {
    var emitter = LiveTranscriptEmitter(insertionDelay: .seconds(1))
    let start = ContinuousClock.now

    #expect(try emitter.consume("We write essays", at: start)?.insertion == "")
    #expect(
        try emitter.consume(
            "We edit essays",
            at: start.advanced(by: .milliseconds(450))
        )?.insertion == ""
    )
    #expect(
        try emitter.consume(
            "We edit essays",
            at: start.advanced(by: .milliseconds(1_500))
        )?.insertion == "We edit"
    )

    let final = try emitter.finalize("We edit essays", continuesAfterPause: false)
    #expect(final?.insertion == " essays.")
}

@Test func lowercaseRestartAfterAnAutomaticPeriodRetractsItAndContinuesTheSentence() throws {
    var emitter = LiveTranscriptEmitter()
    var inserted = ""

    inserted += try emitter.consume("There seems to be a bug right")?.insertion ?? ""
    inserted += try emitter.flushPauseTail("There seems to be a bug right now")?.insertion ?? ""
    inserted += try emitter.finalize("There seems to be a bug right now", continuesAfterPause: true)?.insertion ?? ""
    #expect(inserted == "There seems to be a bug right now.")

    // The first word alone is not enough evidence: nothing is inserted yet.
    let single = try emitter.consume("where")
    #expect(single?.insertion == "")
    #expect(single?.deleteBackward == 0)

    let joined = try #require(try emitter.consume("where the bottom"))
    #expect(joined.deleteBackward == 1)
    #expect(joined.insertion == " where the")
    inserted = String(inserted.dropLast(joined.deleteBackward)) + joined.insertion
    #expect(inserted == "There seems to be a bug right now where the")
    #expect(joined.transcript == "There seems to be a bug right now where the bottom")

    let next = try #require(try emitter.consume("where the bottom bar"))
    #expect(next.deleteBackward == 0)
    inserted += next.insertion
    let final = try #require(try emitter.finalize("where the bottom bar is stuck", continuesAfterPause: false))
    inserted += final.insertion
    #expect(inserted == "There seems to be a bug right now where the bottom bar is stuck.")
    #expect(final.transcript == inserted)
}

@Test func continuationStartersJoinEvenWhenTheDecoderCapitalizesThem() throws {
    var emitter = LiveTranscriptEmitter()
    var inserted = try emitter.finalize("It should keep typing", continuesAfterPause: true)?.insertion ?? ""
    let joined = try #require(try emitter.consume("Until it's done"))
    #expect(joined.deleteBackward == 1)
    #expect(joined.insertion == " until it's")
    inserted = String(inserted.dropLast()) + joined.insertion
    inserted += try emitter.finalize("Until it's done", continuesAfterPause: false)?.insertion ?? ""
    #expect(inserted == "It should keep typing until it's done.")
}

@Test func capitalizedOrdinaryRestartsAndSpokenPeriodsKeepTheSentenceBoundary() throws {
    var emitter = LiveTranscriptEmitter(dictionaryTerms: ["macOS"])
    var inserted = try emitter.finalize("I found a bug", continuesAfterPause: true)?.insertion ?? ""
    let ordinary = try #require(try emitter.consume("The style tab"))
    #expect(ordinary.deleteBackward == 0)
    #expect(ordinary.insertion == " The style")
    inserted += ordinary.insertion
    inserted += try emitter.finalize("The style tab", continuesAfterPause: true)?.insertion ?? ""
    #expect(inserted == "I found a bug. The style tab.")

    // A lowercase product name at a real sentence start is not a restart signal.
    let product = try #require(try emitter.consume("macOS is fine"))
    #expect(product.deleteBackward == 0)
    #expect(product.insertion == " macOS is")
    inserted += product.insertion
    inserted += try emitter.finalize("macOS is fine", continuesAfterPause: true)?.insertion ?? ""

    // A period the person said out loud is never retracted.
    let spokenPeriod = try emitter.finalize("Stop here period", continuesAfterPause: true)
    #expect(spokenPeriod?.insertion == " Stop here.")
    let afterSpoken = try #require(try emitter.consume("and then more"))
    #expect(afterSpoken.deleteBackward == 0)
    #expect(afterSpoken.insertion == " And then")
    _ = try emitter.finalize("and then more", continuesAfterPause: false)
    #expect(emitter.completedText == "I found a bug. The style tab. macOS is fine. Stop here. And then more.")
}

@Test func aJoinDecidedAtFinalizationStillRetractsThePeriod() throws {
    var emitter = LiveTranscriptEmitter()
    _ = try emitter.finalize("I like this better", continuesAfterPause: true)
    let final = try #require(try emitter.finalize("than that", continuesAfterPause: false))
    #expect(final.deleteBackward == 1)
    #expect(final.insertion == " than that.")
    #expect(final.transcript == "I like this better than that.")
}
