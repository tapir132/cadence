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
@Test func modifierOnlyHotKeyFiresOnCleanReleaseOnly() throws {
    let hotKey = GlobalHotKey.shared
    var presses = 0
    hotKey.onPress = { presses += 1 }
    let chord = try #require(ShortcutBinding.modifierOnly([.control, .option]))
    hotKey.binding = chord
    defer {
        hotKey.binding = nil
        hotKey.onPress = nil
    }
    #expect(hotKey.isRegistered)

    hotKey.handleFlags([.control])
    hotKey.handleFlags([.control, .option])
    hotKey.handleFlags([.option])
    hotKey.handleFlags([])
    #expect(presses == 1)

    // ⌃⌥ + another key is a different shortcut, not a chord tap.
    hotKey.handleFlags([.control, .option])
    hotKey.noteKeyDown()
    hotKey.handleFlags([])
    #expect(presses == 1)

    // A different or larger chord never fires.
    hotKey.handleFlags([.command])
    hotKey.handleFlags([])
    hotKey.handleFlags([.control, .option, .command])
    hotKey.handleFlags([])
    #expect(presses == 1)
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

@Test func allFloatingBarPlacementsRoundTrip() throws {
    for placement in BarPlacement.allCases {
        let data = try JSONEncoder().encode(placement)
        #expect(try JSONDecoder().decode(BarPlacement.self, from: data) == placement)
    }
}
