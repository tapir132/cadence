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
