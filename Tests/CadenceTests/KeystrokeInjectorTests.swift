import CoreGraphics
import Testing
@testable import Cadence

/// Injected events must never carry modifier flags: with hold-to-talk the user
/// is holding the shortcut's modifiers while text is typed.
@Test func injectedKeyEventsCarryTheCharacterAndNoModifiers() throws {
    let modifierMasks: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn]
    let events = try #require(KeystrokeInjector.keyEvents(for: "é"))
    #expect(events.down.flags.intersection(modifierMasks).isEmpty)
    #expect(events.up.flags.intersection(modifierMasks).isEmpty)
    #expect(events.down.type == .keyDown)
    #expect(events.up.type == .keyUp)

    var length = 0
    var units = [UniChar](repeating: 0, count: 4)
    events.down.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
    #expect(String(utf16CodeUnits: units, count: length) == "é")
}
