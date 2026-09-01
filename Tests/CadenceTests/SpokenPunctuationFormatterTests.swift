import Testing
@testable import Cadence

@Test func spokenPeriodAndQuestionMarkBecomePunctuation() {
    #expect(SpokenPunctuationFormatter.format("Finish the sentence period") == "Finish the sentence.")
    #expect(SpokenPunctuationFormatter.format("Is this working question mark") == "Is this working?")
    #expect(SpokenPunctuationFormatter.format("Use full stop here") == "Use. here")
}

@Test func punctuationCommandsConsumeAutomaticTerminalPunctuation() {
    #expect(SpokenPunctuationFormatter.format("Finish this period.") == "Finish this.")
    #expect(SpokenPunctuationFormatter.format("Really question mark.") == "Really?")
}

@Test func spokenPunctuationStreamsAndFinalizesWithoutLiteralCommandWords() throws {
    var emitter = LiveTranscriptEmitter()
    var inserted = ""

    inserted += try emitter.consume("This works period")?.insertion ?? ""
    #expect(inserted == "This")
    inserted += try emitter.finalize("This works period", continuesAfterPause: true)?.insertion ?? ""
    #expect(inserted == "This works.")

    inserted += try emitter.consume("Does this work question mark")?.insertion ?? ""
    inserted += try emitter.finalize(
        "Does this work question mark",
        continuesAfterPause: false
    )?.insertion ?? ""
    #expect(inserted == "This works. Does this work?")
}

@Test func partialQuestionMarkCommandNeverCommitsQuestionAsAWord() throws {
    var emitter = LiveTranscriptEmitter()
    var inserted = ""

    inserted += try emitter.consume("Does this command work question ma")?.insertion ?? ""
    #expect(inserted == "Does this command work")

    let completedCommand = try emitter.consume("Does this command work question mark")
    #expect(completedCommand?.transcript == "Does this command work?")
    #expect(completedCommand?.insertion == "")

    inserted += try emitter.finalize(
        "Does this command work question mark",
        continuesAfterPause: false
    )?.insertion ?? ""
    #expect(inserted == "Does this command work?")
}
