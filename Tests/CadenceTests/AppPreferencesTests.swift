import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Cadence

@Test func shortcutDisplayIsStable() {
    #expect(ShortcutBinding.standard.displayText == "⌃⌥Space")
    #expect(ShortcutBinding.standard.keyCode == 49)
}

@Test func keyboardStateFlagsDoNotChangeTheShortcut() {
    let noisy = ShortcutBinding(
        keyCode: 49,
        modifiersRawValue: NSEvent.ModifierFlags([.control, .option, .capsLock, .function, .numericPad]).rawValue,
        keyLabel: "Space"
    )
    #expect(noisy.modifiers == [.control, .option])
    #expect(noisy.carbonModifiers == UInt32(controlKey | optionKey))
    #expect(noisy.displayText == "⌃⌥Space")
}

@MainActor
@Test func bareFunctionKeysAreValidShortcutsButPlainKeysAreNot() throws {
    func event(code: UInt16, flags: NSEvent.ModifierFlags, characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }
    let f5 = try #require(ShortcutBinding.from(try event(code: 96, flags: .function, characters: "\u{F708}")))
    #expect(f5.displayText == "F5")
    #expect(f5.carbonModifiers == 0)
    let f19 = try #require(ShortcutBinding.from(try event(code: 80, flags: .function, characters: "\u{F716}")))
    #expect(f19.displayText == "F19")
    #expect(ShortcutBinding.from(try event(code: 2, flags: [], characters: "d")) == nil)
    #expect(ShortcutBinding.from(try event(code: 2, flags: .shift, characters: "D")) == nil)
    let combo = try #require(ShortcutBinding.from(try event(code: 2, flags: [.command, .shift], characters: "D")))
    #expect(combo.displayText == "⇧⌘D")
    #expect(combo.carbonModifiers == UInt32(cmdKey | shiftKey))
}

@Test func modifierOnlyChordsNeedAPrimaryModifierAndRoundTrip() throws {
    let chord = try #require(ShortcutBinding.modifierOnly([.control, .option, .capsLock]))
    #expect(chord.isModifierOnly)
    #expect(chord.displayText == "⌃⌥")
    #expect(chord.modifiers == [.control, .option])
    #expect(ShortcutBinding.modifierOnly([.shift]) == nil)
    #expect(ShortcutBinding.modifierOnly([]) == nil)
    let data = try JSONEncoder().encode(chord)
    #expect(try JSONDecoder().decode(ShortcutBinding.self, from: data) == chord)
    // Bindings saved before modifier-only chords existed still decode.
    let legacy = Data(#"{"keyLabel":"Space","keyCode":49,"modifiersRawValue":786432}"#.utf8)
    #expect(try JSONDecoder().decode(ShortcutBinding.self, from: legacy) == .standard)
}

@MainActor
@Test func modifierChordPressesWhenCompleteAndReleasesWhenAnyModifierLifts() throws {
    let hotKey = GlobalHotKey.shared
    var events: [String] = []
    hotKey.onPress = { events.append("press") }
    hotKey.onRelease = { events.append("release") }
    let chord = try #require(ShortcutBinding.modifierOnly([.control, .option]))
    hotKey.binding = chord
    defer {
        hotKey.binding = nil
        hotKey.onPress = nil
        hotKey.onRelease = nil
    }
    #expect(hotKey.isRegistered)

    hotKey.handleFlags([.control])
    #expect(events.isEmpty)
    hotKey.handleFlags([.control, .option])
    #expect(events == ["press"])
    hotKey.handleFlags([.control, .option, .shift])
    #expect(events == ["press"])
    hotKey.handleFlags([.option])
    #expect(events == ["press", "release"])
    hotKey.handleFlags([])
    #expect(events == ["press", "release"])

    // Reaching the chord through a larger combination never starts it.
    hotKey.handleFlags([.control, .option, .command])
    hotKey.handleFlags([])
    #expect(events == ["press", "release"])
}

@MainActor
@Test func carbonHotKeyIgnoresAutoRepeatAndReportsRelease() {
    let hotKey = GlobalHotKey.shared
    var events: [String] = []
    hotKey.onPress = { events.append("press") }
    hotKey.onRelease = { events.append("release") }
    hotKey.binding = .standard
    defer {
        hotKey.binding = nil
        hotKey.onPress = nil
        hotKey.onRelease = nil
    }

    hotKey.handleCarbon(isPress: true)
    hotKey.handleCarbon(isPress: true)
    hotKey.handleCarbon(isPress: true)
    hotKey.handleCarbon(isPress: false)
    hotKey.handleCarbon(isPress: false)
    #expect(events == ["press", "release"])
}

@MainActor
@Test func livePasteDoesNotReleaseAnOptionOnlyShortcut() throws {
    let hotKey = GlobalHotKey.shared
    var events: [String] = []
    hotKey.onPress = { events.append("press") }
    hotKey.onRelease = { events.append("release") }
    hotKey.binding = ShortcutBinding.modifierOnly([.option])
    defer {
        hotKey.binding = nil
        hotKey.onPress = nil
        hotKey.onRelease = nil
    }

    hotKey.handleFlags([.option])
    #expect(events == ["press"])

    let pasteEvents = try #require(KeystrokeInjector.pasteCommandEvents())
    for event in pasteEvents where event.type == .flagsChanged {
        hotKey.handleModifierEvent(try #require(NSEvent(cgEvent: event)))
    }
    #expect(events == ["press"])

    // A real Option-up still ends the session.
    hotKey.handleFlags([])
    #expect(events == ["press", "release"])
}

@MainActor
@Test func standardShortcutRegistersAsSystemHotKey() {
    let hotKey = GlobalHotKey.shared
    hotKey.binding = .standard
    defer { hotKey.binding = nil }
    #expect(hotKey.isRegistered)
    hotKey.isSuspended = true
    #expect(!hotKey.isRegistered)
    hotKey.isSuspended = false
    #expect(hotKey.isRegistered)
    hotKey.binding = ShortcutBinding(keyCode: 96, modifiersRawValue: 0, keyLabel: "F5")
    #expect(hotKey.isRegistered)
}

@Test func updateChannelLabelsMatchReleasePolicy() {
    #expect(UpdateChannel.stable.rawValue == "stable")
    #expect(UpdateChannel.stable.title == "Release")
    #expect(UpdateChannel.edge.title == "Edge")
}

@Test func startupUpdatePromptWaitsForSparkleSessionToBecomeReady() {
    var gate = StartupUpdatePromptGate()
    gate.queue()

    let blockedWhileBusy = gate.consumeIfReady(canCheck: false, sessionInProgress: true)
    #expect(!blockedWhileBusy)
    #expect(gate.isPending)
    let blockedUntilSessionEnds = gate.consumeIfReady(canCheck: true, sessionInProgress: true)
    #expect(!blockedUntilSessionEnds)
    #expect(gate.isPending)
    let presentedWhenReady = gate.consumeIfReady(canCheck: true, sessionInProgress: false)
    #expect(presentedWhenReady)
    #expect(!gate.isPending)
    let doesNotPresentTwice = gate.consumeIfReady(canCheck: true, sessionInProgress: false)
    #expect(!doesNotPresentTwice)
}

@Test func allFloatingBarPlacementsRoundTrip() throws {
    for placement in BarPlacement.allCases {
        let data = try JSONEncoder().encode(placement)
        #expect(try JSONDecoder().decode(BarPlacement.self, from: data) == placement)
    }
}

@Test func recognitionProfilesRoundTripAndDescribeTheirTradeoff() throws {
    for profile in RecognitionProfile.allCases {
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(RecognitionProfile.self, from: data) == profile)
    }
    #expect(RecognitionProfile.fast.unifiedConfig.latencyMs == 320)
    #expect(RecognitionProfile.accurate.unifiedConfig.latencyMs == 1_120)
}

@Test func transcriptDeliveryPreferencesRoundTripAndClampTypingSpeed() throws {
    let suiteName = "app.cadence.tests.preferences.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(TranscriptDeliveryPreferences.load(from: defaults) == .defaults)

    let expected = TranscriptDeliveryPreferences(
        typingBufferEnabled: true,
        characterPlaybackEnabled: true,
        characterPlaybackWordsPerMinute: 95,
        characterPlaybackRhythm: .expressive
    )
    expected.save(to: defaults)
    #expect(TranscriptDeliveryPreferences.load(from: defaults) == expected)

    defaults.set(10, forKey: "characterPlaybackWordsPerMinute")
    #expect(
        TranscriptDeliveryPreferences.load(from: defaults).characterPlaybackWordsPerMinute
            == CharacterPlaybackPacing.wordsPerMinuteRange.lowerBound
    )
    defaults.set(500, forKey: "characterPlaybackWordsPerMinute")
    #expect(
        TranscriptDeliveryPreferences.load(from: defaults).characterPlaybackWordsPerMinute
            == CharacterPlaybackPacing.wordsPerMinuteRange.upperBound
    )
}

@Test func dictationProfilesHaveDistinctConfigurationsAndDetectCustomSettings() throws {
    let configurations = try DictationProfile.presets.map {
        try #require($0.configuration)
    }
    #expect(configurations.count == 3)
    #expect(configurations[0] != configurations[1])
    #expect(configurations[0] != configurations[2])
    #expect(configurations[1] != configurations[2])

    for profile in DictationProfile.presets {
        let configuration = try #require(profile.configuration)
        #expect(DictationProfile.matching(configuration) == profile)
    }

    let quick = try #require(DictationProfile.quick.configuration)
    let normal = try #require(DictationProfile.normal.configuration)
    let essay = try #require(DictationProfile.essay.configuration)
    #expect(!quick.delivery.characterPlaybackEnabled)
    #expect(!normal.delivery.characterPlaybackEnabled)
    #expect(essay.delivery.characterPlaybackEnabled)

    #expect(quick.cleanup == .none)
    #expect(normal.cleanup == .light)
    #expect(essay.cleanup == .medium)

    let personalizedEssay = DictationConfiguration(
        recognitionProfile: essay.recognitionProfile,
        cleanup: essay.cleanup,
        delivery: TranscriptDeliveryPreferences(
            typingBufferEnabled: essay.delivery.typingBufferEnabled,
            characterPlaybackEnabled: essay.delivery.characterPlaybackEnabled,
            characterPlaybackWordsPerMinute: 145,
            characterPlaybackRhythm: .expressive
        )
    )
    #expect(DictationProfile.matching(personalizedEssay) == .essay)

    let custom = DictationConfiguration(
        recognitionProfile: .accurate,
        cleanup: .medium,
        delivery: TranscriptDeliveryPreferences(
            typingBufferEnabled: false,
            characterPlaybackEnabled: true,
            characterPlaybackWordsPerMinute: 135,
            characterPlaybackRhythm: .steady
        )
    )
    #expect(DictationProfile.matching(custom) == .custom)

    let normalWithoutCleanup = DictationConfiguration(
        recognitionProfile: normal.recognitionProfile,
        cleanup: .none,
        delivery: normal.delivery
    )
    #expect(DictationProfile.matching(normalWithoutCleanup) == .custom)
}

@Test func legacyTimingVariationMigratesToNaturalRhythm() throws {
    let suiteName = "app.cadence.tests.preferences.legacy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(true, forKey: "characterPlaybackTimingVariationEnabled")
    #expect(TranscriptDeliveryPreferences.load(from: defaults).characterPlaybackRhythm == .natural)

    defaults.set(CharacterPlaybackRhythm.expressive.rawValue, forKey: "characterPlaybackRhythm")
    #expect(TranscriptDeliveryPreferences.load(from: defaults).characterPlaybackRhythm == .expressive)
}
