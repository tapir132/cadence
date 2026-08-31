import Testing
@testable import Cadence

@Test func waitsForRepeatedHypothesisAndHoldback() {
    var stabilizer = TranscriptStabilizer(holdbackWords: 1)
    #expect(stabilizer.consume("Hello brave", isFinal: false) == "")
    #expect(stabilizer.consume("Hello brave new", isFinal: false) == "Hello")
    #expect(stabilizer.consume("Hello brave new world", isFinal: false) == " brave")
    #expect(stabilizer.consume("Hello brave new world", isFinal: true) == " new world")
}

@Test func neverRewritesCommittedWords() {
    var stabilizer = TranscriptStabilizer(holdbackWords: 0)
    _ = stabilizer.consume("I like", isFinal: false)
    #expect(stabilizer.consume("I like", isFinal: false) == "I like")
    #expect(stabilizer.consume("I love this", isFinal: false) == "")
    #expect(stabilizer.committedTokens == ["I", "like"])
}

@Test func finalResultFlushesTheTail() {
    var stabilizer = TranscriptStabilizer(holdbackWords: 2)
    _ = stabilizer.consume("One two three", isFinal: false)
    #expect(stabilizer.consume("One two three four", isFinal: false) == "One")
    #expect(stabilizer.flush("One two three four") == " two three four")
}
