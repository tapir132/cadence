import Testing
@testable import Cadence

@Test func fillerCleanupRemovesOnlyStandaloneHesitations() {
    #expect(SpeechCleanupFormatter.format("Um, this is uh a test", enabled: true) == "This is a test")
    #expect(SpeechCleanupFormatter.format("I, um, think this works", enabled: true) == "I think this works")
    #expect(SpeechCleanupFormatter.format("um uh erm okay", enabled: true) == "Okay")
    #expect(SpeechCleanupFormatter.format("Hmm, this may work", enabled: true) == "This may work")
    #expect(SpeechCleanupFormatter.format("the drummer and her friend", enabled: true) == "the drummer and her friend")
    #expect(SpeechCleanupFormatter.format("uh-huh, that works", enabled: true) == "uh-huh, that works")
    #expect(SpeechCleanupFormatter.format("um iPhone works", enabled: true) == "iPhone works")
}

@Test func fillerCleanupUsesDiscourseContextInsteadOfAWordBlacklist() {
    #expect(
        SpeechCleanupFormatter.format(
            "Well, I, you know, think it is, like, ready",
            enabled: true
        ) == "I think it is ready"
    )
    #expect(
        SpeechCleanupFormatter.format(
            "I like this. Do you know Liam? It is well designed.",
            enabled: true
        ) == "I like this. Do you know Liam? It is well designed."
    )
    #expect(
        SpeechCleanupFormatter.format("I mean, this is clearer", enabled: true)
            == "This is clearer"
    )
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

@Test func liveFillerCleanupDoesNotRewriteACompletedRestart() {
    let spoken = "There needs to be like there needs to be like a randomizer."
    #expect(SpeechCleanupFormatter.format(spoken, enabled: true) == spoken)
}

@Test func deeperCleanupRepairsTheReportedRestartOnlyAtTheEnd() {
    let spoken = "There needs to be like there needs to be like a randomizer and then like a words per minute slider. You can toggle. You can toggle. Like. How fast the words per minute is."
    #expect(
        DeepSpeechCleanupFormatter.format(spoken, enabled: true)
            == "There needs to be like a randomizer and then like a words per minute slider. You can toggle how fast the words per minute is."
    )
    #expect(DeepSpeechCleanupFormatter.format(spoken, enabled: false) == spoken)
}

@Test func deeperCleanupPreservesLegitimateSingleWordRepetitionAndLike() {
    let spoken = "It was very very good. I like that. Had had is unusual but valid."
    #expect(DeepSpeechCleanupFormatter.format(spoken, enabled: true) == spoken)
    #expect(DeepSpeechCleanupFormatter.format("Like.", enabled: true) == "Like.")
}

@Test func deeperCleanupUsesRepairAnchorsAroundEditingTerms() {
    let spoken = "I think we should, I mean, I think we can ship this today."
    #expect(
        DeepSpeechCleanupFormatter.format(spoken, enabled: true)
            == "I think we can ship this today."
    )

    let ambiguous = "Meet Tuesday, I mean Wednesday. I mean what I say."
    #expect(DeepSpeechCleanupFormatter.format(ambiguous, enabled: true) == ambiguous)
}

@Test func deeperCleanupJoinsGrammarDrivenFalseSentenceBoundaries() {
    let spoken = "The whole point of the app. Is that it should feel natural. You can choose. How quickly it types."
    #expect(
        DeepSpeechCleanupFormatter.format(spoken, enabled: true)
            == "The whole point of the app is that it should feel natural. You can choose how quickly it types."
    )

    let explicitParagraph = "The whole point of the app.\n\nIs that a question?"
    #expect(DeepSpeechCleanupFormatter.format(explicitParagraph, enabled: true) == explicitParagraph)
}
