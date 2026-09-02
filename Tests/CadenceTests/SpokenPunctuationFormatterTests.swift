import Testing
@testable import Cadence

@Test func spokenPeriodAndQuestionMarkBecomePunctuation() {
    #expect(SpokenPunctuationFormatter.format("Finish the sentence period") == "Finish the sentence.")
    #expect(SpokenPunctuationFormatter.format("Is this working question mark") == "Is this working?")
    #expect(SpokenPunctuationFormatter.format("Use full stop here") == "Use. here")
}

@Test func commaAndParagraphCommandsMatchMacDictationConventions() {
    let transcript = "Hello, doctor Solarz, comma New paragraph. I can come during tutorial. period new paragraph Thank you period New paragraph Liam"
    let punctuated = SpokenPunctuationFormatter.format(transcript)
    let styled = SpokenStyleFormatter.format(punctuated)

    #expect(
        styled
            == "Hello, Dr. Solarz,\n\nI can come during tutorial.\n\nThank you.\n\nLiam"
    )
}

@Test func punctuationCommandsReplaceExistingModelPunctuation() {
    #expect(SpokenPunctuationFormatter.format("Done. period") == "Done.")
    #expect(SpokenPunctuationFormatter.format("Really. question mark.") == "Really?")
    #expect(SpokenPunctuationFormatter.format("Hello, comma") == "Hello,")
    #expect(SpokenPunctuationFormatter.format("Wait, comma new paragraph. Next") == "Wait,\n\nNext")
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

@Test func partialParagraphCommandNeverLeaksCommandWords() throws {
    var emitter = LiveTranscriptEmitter()
    var inserted = ""

    inserted += try emitter.consume("Thank you period new par")?.insertion ?? ""
    #expect(inserted == "Thank you.")

    inserted += try emitter.consume("Thank you period new paragraph Liam")?.insertion ?? ""
    inserted += try emitter.finalize(
        "Thank you period new paragraph Liam",
        continuesAfterPause: false
    )?.insertion ?? ""
    #expect(inserted == "Thank you.\n\nLiam.")
}

@Test func paragraphCommandSurvivesItsOwnPauseAndCapitalizesTheNextSegment() throws {
    var emitter = LiveTranscriptEmitter()
    var inserted = ""

    inserted += try emitter.finalize(
        "Thank you period",
        continuesAfterPause: true
    )?.insertion ?? ""
    inserted += try emitter.finalize(
        "new paragraph",
        continuesAfterPause: true
    )?.insertion ?? ""
    inserted += try emitter.finalize(
        "liam",
        continuesAfterPause: false
    )?.insertion ?? ""

    #expect(inserted == "Thank you.\n\nLiam.")
    #expect(emitter.completedText == inserted)
}
