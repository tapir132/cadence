import AppKit
import Testing
@testable import Cadence

@Suite("Floating bar snap geometry")
struct SnapGeometryTests {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)
    private let control = NSSize(width: 48, height: 48)

    @Test func providesEightUniqueInBoundsDestinations() {
        let origins = SnapSlot.allCases.map { SnapGeometry.origin(for: $0, size: control, in: screen) }
        let unique = Set(origins.map { "\($0.x),\($0.y)" })

        #expect(origins.count == 8)
        #expect(unique.count == 8)
        for origin in origins {
            #expect(origin.x >= screen.minX)
            #expect(origin.y >= screen.minY)
            #expect(origin.x + control.width <= screen.maxX)
            #expect(origin.y + control.height <= screen.maxY)
        }
    }

    @Test func everyDestinationMapsBackToItsOwnSlot() {
        for slot in SnapSlot.allCases {
            let origin = SnapGeometry.origin(for: slot, size: control, in: screen)
            #expect(SnapGeometry.nearestSlot(to: origin, size: control, in: screen) == slot)
        }
    }

    @Test func freePlacementIsClampedInsideVisibleFrame() {
        let low = SnapGeometry.clamped(NSPoint(x: -500, y: -200), size: control, in: screen)
        let high = SnapGeometry.clamped(NSPoint(x: 9_000, y: 8_000), size: control, in: screen)

        #expect(low == screen.origin)
        #expect(high == NSPoint(x: screen.maxX - control.width, y: screen.maxY - control.height))
    }

    @Test func singleClickOnlyDragsAndDoubleClickOpens() {
        #expect(FloatingClickAction(clickCount: 1) == .drag)
        #expect(FloatingClickAction(clickCount: 2) == .open)
        #expect(FloatingClickAction(clickCount: 3) == .ignore)
    }

}
