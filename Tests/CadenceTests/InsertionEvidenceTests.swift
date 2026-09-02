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

@Test func insertionEvidenceRejectsWhitespaceSubstitutionDespiteCursorAdvance() {
    let evidence = InsertionEvidence(
        postingFailed: false,
        targetApplicationChanged: false,
        focusedElementChanged: false,
        originalValue: "Prompt: ",
        currentValue: "Prompt: first  second",
        originalSelection: CFRange(location: 8, length: 0),
        currentSelection: CFRange(location: 21, length: 0)
    )

    #expect(
        InsertionEvidenceClassifier.classify(
            evidence,
            insertedText: "first\nsecond"
        ) == .failed
    )
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
