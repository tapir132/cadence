import Foundation
import Testing
@testable import Cadence

@Test func shortcutDisplayIsStable() {
    #expect(ShortcutBinding.standard.displayText == "⌃⌥Space")
    #expect(ShortcutBinding.standard.keyCode == 49)
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
