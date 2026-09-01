import Foundation
import Testing
@testable import Cadence

private func snippet(
    _ trigger: String,
    _ replacement: String,
    id: UUID = UUID()
) -> TextSnippet {
    TextSnippet(
        id: id,
        trigger: trigger,
        replacement: replacement,
        createdAt: .distantPast,
        updatedAt: .distantPast
    )
}

@Test func snippetReplacesOnlyExactWholeTriggerPhrases() {
    let saved = [snippet("my résumé", "https://example.com/resume")]

    #expect(
        SnippetFormatter.format("Open MY RESUME", snippets: saved).text
            == "Open https://example.com/resume"
    )
    #expect(
        SnippetFormatter.format("That is my résumeworthy draft", snippets: saved).text
            == "That is my résumeworthy draft"
    )

    let contraction = [snippet("can", "EXPANDED")]
    #expect(SnippetFormatter.format("I can't", snippets: contraction).text == "I can't")
}

@Test func snippetKeepsAnIncompleteOrTrailingTriggerProvisional() {
    let saved = [snippet("my email", "writer@example.com")]

    let incomplete = SnippetFormatter.format("Please use my", snippets: saved)
    #expect(incomplete.text == "Please use my")
    #expect(incomplete.safePrefixCharacterCount == "Please use".count)

    let complete = SnippetFormatter.format("Please use my email", snippets: saved)
    #expect(complete.text == "Please use writer@example.com")
    #expect(complete.safePrefixCharacterCount == "Please use".count)

    let confirmed = SnippetFormatter.format("Please use my email today", snippets: saved)
    #expect(confirmed.text == "Please use writer@example.com today")
    #expect(confirmed.safePrefixCharacterCount == nil)
}

@Test func snippetPreservesInternalNewlinesAndDoesNotRecursivelyExpand() {
    let saved = [
        snippet("meeting link", "First line\nSecond line"),
        snippet("first line", "This must not replace expansion text")
    ]

    let result = SnippetFormatter.format("Use meeting link now", snippets: saved)
    #expect(result.text == "Use First line\nSecond line now")
}

@Test func incompleteTriggerBoundaryMapsAcrossAnEarlierExpansion() {
    let saved = [
        snippet("meeting link", "https://example.com/meet"),
        snippet("my email", "writer@example.com")
    ]

    let result = SnippetFormatter.format(
        "Use meeting link then my",
        snippets: saved
    )
    #expect(result.text == "Use https://example.com/meet then my")
    #expect(result.safePrefixCharacterCount == "Use https://example.com/meet then".count)
}

@Test func longestAvailableTriggerWinsAtTheSamePosition() {
    let saved = [
        snippet("my email", "short@example.com"),
        snippet("my email address", "long@example.com")
    ]

    // Invalid overlapping preferences are handled conservatively: the longer
    // trigger remains usable and the shorter one cannot force a live rewrite.
    let result = SnippetFormatter.format("Use my email address now", snippets: saved)
    #expect(result.text == "Use long@example.com now")
}

@Test func snippetValidatorRejectsDuplicatesAndUnsafeTriggerPrefixes() {
    let existing = snippet("my email", "writer@example.com")

    #expect(
        TextSnippetValidator.validate(
            trigger: "  MY   EMAIL ",
            replacement: "another@example.com",
            among: [existing]
        ) == .duplicateTrigger("my email")
    )
    #expect(
        TextSnippetValidator.validate(
            trigger: "my email address",
            replacement: "another@example.com",
            among: [existing]
        ) == .overlappingTrigger("my email")
    )
    #expect(
        TextSnippetValidator.validate(
            trigger: "email",
            replacement: "another@example.com",
            among: [existing]
        ) == nil
    )
    #expect(
        TextSnippetValidator.validate(
            trigger: "insert question mark response",
            replacement: "Saved text",
            among: []
        ) == .reservedTrigger
    )
}

@Test func liveEmitterExpandsSnippetOnlyAfterItIsSafe() throws {
    var emitter = LiveTranscriptEmitter(
        snippets: [snippet("my email", "writer@example.com")]
    )
    var inserted = ""

    inserted += try emitter.consume("Send my")?.insertion ?? ""
    #expect(inserted == "Send")

    inserted += try emitter.consume("Send my email")?.insertion ?? ""
    #expect(inserted == "Send")
    #expect(emitter.transcript == "Send writer@example.com")

    inserted += try emitter.consume("Send my email today")?.insertion ?? ""
    #expect(inserted == "Send writer@example.com")

    inserted += try emitter.finalize(
        "Send my email today",
        continuesAfterPause: false
    )?.insertion ?? ""
    #expect(inserted == "Send writer@example.com today.")
}

@Test func pauseFlushesACompleteSingleWordSnippet() throws {
    var emitter = LiveTranscriptEmitter(
        snippets: [snippet("signature", "Kind regards,\nTaylor")]
    )

    #expect(try emitter.consume("signature")?.insertion == "")
    let pause = try emitter.flushPauseTail("signature")
    #expect(pause?.transcript == "Kind regards,\nTaylor")
    #expect(pause?.insertion == "Kind regards,\nTaylor")
}

@Test func punctuationAfterATriggerDoesNotCommitPartOfAMultilineExpansion() throws {
    var emitter = LiveTranscriptEmitter(
        snippets: [snippet("signature", "Kind regards,\nTaylor")]
    )

    #expect(try emitter.consume("signature.")?.insertion == "")
    let final = try emitter.finalize("signature.", continuesAfterPause: false)
    #expect(final?.insertion == "Kind regards,\nTaylor.")
}

@Test func standaloneSnippetStaysExactUnlessPunctuationWasSpoken() throws {
    let saved = [snippet("signature", "Kind regards,\nTaylor")]
    var bareEmitter = LiveTranscriptEmitter(snippets: saved)
    var punctuatedEmitter = LiveTranscriptEmitter(snippets: saved)

    let bare = try bareEmitter.finalize("signature", continuesAfterPause: false)
    #expect(bare?.insertion == "Kind regards,\nTaylor")

    let punctuated = try punctuatedEmitter.finalize(
        "signature period",
        continuesAfterPause: false
    )
    #expect(punctuated?.insertion == "Kind regards,\nTaylor.")
}

@Test func typingBufferCanWithdrawAFalseSnippetBeforeAnythingIsInserted() throws {
    var emitter = LiveTranscriptEmitter(
        snippets: [snippet("my email", "writer@example.com")],
        insertionDelay: .seconds(1)
    )
    let start = ContinuousClock.now

    #expect(
        try emitter.consume("Use my email today", at: start)?.insertion == ""
    )
    #expect(
        try emitter.consume(
            "Use my evil today",
            at: start.advanced(by: .milliseconds(450))
        )?.insertion == ""
    )
    #expect(
        try emitter.consume(
            "Use my evil today",
            at: start.advanced(by: .milliseconds(1_500))
        )?.insertion == "Use my evil"
    )
    #expect(emitter.transcript == "Use my evil today")
}

@Test func snippetStoreRoundTripsPrivateMultilineTextAtomically() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CadenceSnippetStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TextSnippetStore(fileURL: directory.appendingPathComponent("snippets.json"))
    let saved = [snippet("private prompt", "First line\nSecond line")]

    try store.save(saved)
    #expect(try store.load() == saved)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
