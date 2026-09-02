import AppKit
import CoreGraphics
import Testing
@testable import Cadence

@Test func pasteCommandUsesACompletePhysicalKeySequence() throws {
    let events = try #require(KeystrokeInjector.pasteCommandEvents())
    #expect(events.count == 4)
    #expect(events.map(\.type) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
    #expect(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [0x37, 0x09, 0x09, 0x37])
    #expect(events[0].flags.contains(.maskCommand))
    #expect(events[1].flags.contains(.maskCommand))
    #expect(events[2].flags.contains(.maskCommand))
    #expect(!events[3].flags.contains(.maskCommand))
    for event in events {
        #expect(event.getIntegerValueField(.eventSourceUserData) == CadenceSyntheticEvent.pasteCommandMarker)
        let appKitEvent = try #require(NSEvent(cgEvent: event))
        #expect(CadenceSyntheticEvent.isPasteCommand(appKitEvent))
    }
}

@MainActor
@Test func pasteboardPreservesACompleteUnicodeTranscript() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let transcript = "First words, a pause… then café 日本語 and the final words."

    #expect(KeystrokeInjector.write(transcript, to: pasteboard))
    #expect(pasteboard.string(forType: .string) == transcript)
}

@Test func characterPlaybackUsesCompleteGraphemesAndStaysSeparateFromChunking() {
    let text = "A café 👨‍👩‍👧‍👦\n"
    let characterMode = TextDeliveryMode.characterByCharacter(CharacterPlaybackPacing())
    #expect(TextDeliveryMode.chunked.units(for: text) == [text])
    #expect(
        characterMode.units(for: text) == text.map(String.init)
    )
    #expect(
        characterMode.units(for: "👨‍👩‍👧‍👦").count == 1
    )
}

@Test func characterPlaybackPacingUsesWPMAndLanguageAwareRhythms() {
    let steady = CharacterPlaybackPacing(wordsPerMinute: 120)
    #expect(steady.intervalMilliseconds() == 100)

    let natural = CharacterPlaybackPacing(
        wordsPerMinute: 120,
        rhythm: .natural
    )
    #expect(natural.intervalMilliseconds(after: "a", randomUnit: 0) < 100)
    #expect(natural.intervalMilliseconds(after: "a", randomUnit: 0.5) == 95)
    #expect(natural.intervalMilliseconds(after: " ", randomUnit: 0.5) == 120)
    #expect(natural.intervalMilliseconds(after: ".", randomUnit: 0.5) == 180)
    #expect(natural.intervalMilliseconds(after: "\n", randomUnit: 0.5) == 240)

    let expressive = CharacterPlaybackPacing(wordsPerMinute: 120, rhythm: .expressive)
    #expect(
        expressive.intervalMilliseconds(after: ".", randomUnit: 1)
            > natural.intervalMilliseconds(after: ".", randomUnit: 1)
    )

    #expect(CharacterPlaybackPacing(wordsPerMinute: 10).wordsPerMinute == 40)
    #expect(CharacterPlaybackPacing(wordsPerMinute: 500).wordsPerMinute == 160)
}
