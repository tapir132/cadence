import Testing
@testable import Cadence

@Test func livePunctuationClosesAConfidentSentenceBoundary() {
    #expect(PauseBoundaryClassifier.classify("That is a complete sentence.") == .complete)
    #expect(PauseBoundaryClassifier.classify("Does this work?") == .complete)
    #expect(PauseBoundaryClassifier.classify("It does!") == .complete)
}

@Test func dependentClausesStayOpenAcrossAPause() {
    #expect(PauseBoundaryClassifier.classify("Because my Apple dictation") == .continuation)
    #expect(PauseBoundaryClassifier.classify("If this is still running") == .continuation)
    #expect(PauseBoundaryClassifier.classify("Especially when I pause") == .continuation)
    #expect(PauseBoundaryClassifier.classify("I wanted to try this, too") == .uncertain)
}

@Test func clearContinuationEndingsStayOpen() {
    #expect(PauseBoundaryClassifier.classify("I bought the") == .continuation)
    #expect(PauseBoundaryClassifier.classify("This works as well as") == .continuation)
    #expect(PauseBoundaryClassifier.classify("I wanted apples, pears,") == .continuation)
    #expect(PauseBoundaryClassifier.classify("This is probably complete") == .uncertain)
}

@Test func naturalThinkingFragmentsStayOpenUntilTheirPredicateArrives() {
    #expect(PauseBoundaryClassifier.classify("A lot of the text, like") == .continuation)
    #expect(PauseBoundaryClassifier.classify("But the whole") == .continuation)
    #expect(PauseBoundaryClassifier.classify("The whole point of the app") == .continuation)
    #expect(PauseBoundaryClassifier.classify("Is that") == .continuation)
    #expect(PauseBoundaryClassifier.classify("I like that") == .uncertain)
}

@Test func spokenPunctuationIsClassifiedAfterFormatting() {
    let emitter = LiveTranscriptEmitter()
    #expect(emitter.pauseBoundaryDecision(for: "Finish this period") == .complete)
    #expect(emitter.pauseBoundaryDecision(for: "Is this right question mark") == .complete)
}
