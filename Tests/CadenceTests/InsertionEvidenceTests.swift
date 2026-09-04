import Foundation
import Testing
@testable import Cadence

@Test func insertionEvidenceConfirmsCursorAdvance() {
    let evidence = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: false,
        focusedElementChanged: false,
        originalValue: nil,
        currentValue: nil,
        originalSelection: CFRange(location: 10, length: 0),
        currentSelection: CFRange(location: 15, length: 0)
    )
    #expect(InsertionEvidenceClassifier.classify(evidence, insertedText: "hello") == .confirmed)
}

@Test func insertionEvidenceDetectsUnchangedEditor() {
    let evidence = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: false,
        focusedElementChanged: false,
        originalValue: "Draft",
        currentValue: "Draft",
        originalSelection: CFRange(location: 5, length: 0),
        currentSelection: CFRange(location: 5, length: 0)
    )
    #expect(InsertionEvidenceClassifier.classify(evidence, insertedText: " hello") == .failed)
}

@Test func insertionEvidenceAcceptsWhitespaceReflowedText() {
    // Terminal wraps a long line and a single-line field turns a paragraph
    // break into spaces; the words arrived either way.
    let wrapped = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: false,
        focusedElementChanged: false,
        originalValue: "% ",
        currentValue: "% Need you to look up how to implement the style\ntab and all of those things.",
        originalSelection: CFRange(location: 2, length: 0),
        currentSelection: CFRange(location: 80, length: 0)
    )
    #expect(
        InsertionEvidenceClassifier.classify(
            wrapped,
            insertedText: "Need you to look up how to implement the style tab and all of those things."
        ) == .confirmed
    )

    let flattened = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: false,
        focusedElementChanged: false,
        originalValue: "Prompt: ",
        currentValue: "Prompt: first  second",
        originalSelection: CFRange(location: 8, length: 0),
        currentSelection: CFRange(location: 21, length: 0)
    )
    #expect(InsertionEvidenceClassifier.classify(flattened, insertedText: "first\nsecond") == .confirmed)
}

@Test func insertionEvidenceTreatsAnOtherwiseChangedDocumentAsUnverifiable() {
    // The composer emptied because the message was sent, or the editor
    // rewrote the text: neither proves the paste was lost.
    let sent = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: false,
        focusedElementChanged: false,
        originalValue: "Message #general\nold draft",
        currentValue: "Message #general",
        originalSelection: CFRange(location: 26, length: 0),
        currentSelection: CFRange(location: 0, length: 0)
    )
    #expect(InsertionEvidenceClassifier.classify(sent, insertedText: " hello there") == .unavailable)
}

@Test func deliveryTimeConfirmationSurvivesALaterSendOrEdit() {
    #expect(InsertionEvidenceClassifier.merged(atDelivery: .confirmed, afterCompletion: .failed, postingFailed: false) == .confirmed)
    #expect(InsertionEvidenceClassifier.merged(atDelivery: .confirmed, afterCompletion: .unavailable, postingFailed: false) == .confirmed)
    #expect(InsertionEvidenceClassifier.merged(atDelivery: .unavailable, afterCompletion: .failed, postingFailed: false) == .failed)
    #expect(InsertionEvidenceClassifier.merged(atDelivery: nil, afterCompletion: .confirmed, postingFailed: false) == .confirmed)
    #expect(InsertionEvidenceClassifier.merged(atDelivery: .confirmed, afterCompletion: .confirmed, postingFailed: true) == .failed)
}

@Test func insertionEvidenceConfirmsExactLocalTextFromContentEditableEditor() {
    // Chromium content-editables can expose a container-level value before the
    // paste, then a leaf-level value afterward. The complete document strings
    // are not directly comparable, but the exact text immediately before the
    // reported caret is.
    let inserted = "You got to take the risk to have fun sometimes, you know?"
    let current = "Message #general\n\(inserted)"
    let evidence = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: false,
        focusedElementChanged: false,
        originalValue: "Message #general",
        currentValue: current,
        originalSelection: CFRange(location: 0, length: 0),
        currentSelection: CFRange(location: current.utf16.count, length: 0)
    )

    #expect(InsertionEvidenceClassifier.classify(evidence, insertedText: inserted) == .confirmed)
}

@Test func insertionEvidenceTrustsExactTextWhenContentEditableCaretIsStale() {
    let inserted = "You got to take the risk to have fun sometimes, you know?"
    let evidence = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: false,
        focusedElementChanged: false,
        originalValue: "",
        currentValue: inserted,
        originalSelection: CFRange(location: 0, length: 0),
        currentSelection: CFRange(location: 0, length: 0)
    )

    #expect(InsertionEvidenceClassifier.classify(evidence, insertedText: inserted) == .confirmed)
}

@Test func insertionEvidenceDoesNotMistakePreexistingMatchingTextForAPaste() {
    let evidence = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: false,
        focusedElementChanged: false,
        originalValue: "hello",
        currentValue: "hello",
        originalSelection: CFRange(location: 5, length: 0),
        currentSelection: CFRange(location: 5, length: 0)
    )

    #expect(InsertionEvidenceClassifier.classify(evidence, insertedText: "hello") == .failed)
}

@Test func insertionEvidenceTreatsOpaqueEditorsAsUnavailable() {
    let evidence = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: false,
        focusedElementChanged: false,
        originalValue: nil,
        currentValue: nil,
        originalSelection: nil,
        currentSelection: nil
    )
    #expect(InsertionEvidenceClassifier.classify(evidence, insertedText: "hello") == .unavailable)
}

@Test func insertionEvidenceDoesNotReportFailureForARecreatedTextElement() {
    let evidence = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: false,
        focusedElementChanged: true,
        originalValue: "Draft",
        currentValue: "Draft",
        originalSelection: CFRange(location: 5, length: 0),
        currentSelection: CFRange(location: 5, length: 0)
    )
    #expect(InsertionEvidenceClassifier.classify(evidence, insertedText: " hello") == .unavailable)
}

@Test func insertionEvidenceDetectsTargetChangeOrPostingFailure() {
    let changedTarget = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: true,
        focusedElementChanged: false,
        originalValue: nil,
        currentValue: nil,
        originalSelection: nil,
        currentSelection: nil
    )
    #expect(InsertionEvidenceClassifier.classify(changedTarget, insertedText: "hello") == .failed)

    let postFailure = InsertionEvidence(
        postingFailed: true,
        targetApplicationChanged: false,
        focusedElementChanged: false,
        originalValue: nil,
        currentValue: nil,
        originalSelection: nil,
        currentSelection: nil
    )
    #expect(InsertionEvidenceClassifier.classify(postFailure, insertedText: "hello") == .failed)
}

@Test func deepEditingSelectsOnlyTheVerifiedInsertedSpan() {
    let inserted = "café 👨‍👩‍👧‍👦"
    let expected = CFRange(location: 6, length: inserted.utf16.count)
    let evidence = InsertedTextRewriteEvidence(
        originalValue: "Intro ending",
        currentValue: "Intro \(inserted)ending",
        originalSelection: CFRange(location: 6, length: 0),
        currentSelection: CFRange(location: 6 + inserted.utf16.count, length: 0)
    )
    let selection = InsertedTextRewritePlanner.selectionRange(
        for: inserted,
        evidence: evidence
    )
    #expect(selection?.location == expected.location)
    #expect(selection?.length == expected.length)
}

@Test func deepEditingFailsClosedAfterDocumentOrCursorChanges() {
    let base = InsertedTextRewriteEvidence(
        originalValue: "Draft",
        currentValue: "Draft dictated text",
        originalSelection: CFRange(location: 5, length: 0),
        currentSelection: CFRange(location: 19, length: 0)
    )
    #expect(InsertedTextRewritePlanner.selectionRange(for: " dictated text", evidence: base) != nil)

    let changedDocument = InsertedTextRewriteEvidence(
        originalValue: base.originalValue,
        currentValue: "Draft user edit dictated text",
        originalSelection: base.originalSelection,
        currentSelection: base.currentSelection
    )
    #expect(InsertedTextRewritePlanner.selectionRange(for: " dictated text", evidence: changedDocument) == nil)

    let movedCursor = InsertedTextRewriteEvidence(
        originalValue: base.originalValue,
        currentValue: base.currentValue,
        originalSelection: base.originalSelection,
        currentSelection: CFRange(location: 10, length: 0)
    )
    #expect(InsertedTextRewritePlanner.selectionRange(for: " dictated text", evidence: movedCursor) == nil)
}
