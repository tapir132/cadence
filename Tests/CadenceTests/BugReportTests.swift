import Foundation
import Testing
@testable import Cadence

@Test func bugReportEncodesSupportContextAndRecentTranscripts() throws {
    let date = try #require(ISO8601DateFormatter().date(from: "2026-09-03T02:00:00Z"))
    let report = CadenceBugReport(
        reportFormatVersion: 1,
        generatedAt: date,
        privacy: CadenceBugReport.privacyNotice,
        application: .init(version: "0.3.2-edge.abcdef0", build: "42", bundleIdentifier: "app.cadence.mac"),
        system: .init(operatingSystem: "macOS 26.0", architecture: "arm64"),
        permissions: .init(microphone: true, accessibility: true),
        settings: .init(
            dictationProfile: "normal",
            recognitionProfile: "fast",
            autoCleanup: "light",
            fillerWordCleanup: true,
            deeperEditing: false,
            stabilityBuffer: true,
            characterPlayback: false,
            characterPlaybackWordsPerMinute: 120,
            characterPlaybackRhythm: "steady",
            pausesMusic: true,
            shortcut: .init(display: "⌃⌥⌘D", keyCode: 2, modifierFlags: 1),
            floatingBar: .init(placement: "bottom", scale: 1, freePositionX: 0.5, freePositionY: 0),
            updates: .init(channel: "edge", checksAutomatically: true, downloadsAutomatically: true),
            customDictionaryTermCount: 3,
            snippetCount: 2,
            writingStyles: ["personalMessages": "casual", "email": "formal"]
        ),
        status: .init(
            dictation: "idle",
            dictationError: nil,
            speechModel: "ready",
            speechModelError: nil,
            speechModelPreparationProgress: nil,
            insertionRecoveryVisible: true,
            insertionRecoveryTargetApplication: "Discord"
        ),
        recentDictations: (1...CadenceBugReport.transcriptLimit).map { index in
            .init(
                date: date,
                text: "Transcript \(index)",
                targetApplication: "Discord",
                durationSeconds: 5,
                wordsPerMinute: 120,
                insertionVerification: InsertionVerificationResult.confirmed.rawValue
            )
        }
    )

    let data = try report.encodedData()
    let encoded = try #require(String(data: data, encoding: .utf8))
    #expect(encoded.contains("0.3.2-edge.abcdef0"))
    #expect(encoded.contains("Transcript 3"))
    #expect(encoded.contains("insertionVerification"))
    #expect(encoded.contains("\"personalMessages\" : \"casual\""))
    #expect(encoded.contains(CadenceBugReport.privacyNotice))
    #expect(!encoded.contains("clipboardContents"))
}

@Test func bugReportFilenameIsPredictableAndSafe() throws {
    let date = try #require(ISO8601DateFormatter().date(from: "2026-09-03T02:04:05Z"))
    #expect(CadenceBugReport.suggestedFilename(at: date).hasPrefix("Cadence-Bug-Report-2026-09-"))
    #expect(CadenceBugReport.suggestedFilename(at: date).hasSuffix(".json"))
    #expect(!CadenceBugReport.suggestedFilename(at: date).contains(":"))
}

@Test func savedDictationsFromBeforeVerificationDiagnosticsStillDecode() throws {
    let data = Data(#"{"id":"76D8C4A2-74D0-4B18-AF46-916B17378509","date":0,"text":"Earlier transcript","appName":"Notes","duration":3,"wordsPerMinute":80}"#.utf8)
    let record = try JSONDecoder().decode(DictationRecord.self, from: data)
    #expect(record.text == "Earlier transcript")
    #expect(record.insertionVerification == nil)
}
