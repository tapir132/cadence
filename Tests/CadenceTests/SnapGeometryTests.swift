import AppKit
import SwiftUI
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

    @MainActor
    @Test func idleControlCollapsesTowardItsConfiguredEdge() {
        #expect(mode(placement: .top) == .collapsed(.top))
        #expect(mode(placement: .right) == .collapsed(.right))
        #expect(mode(placement: .bottom) == .collapsed(.bottom))
        #expect(mode(placement: .left) == .collapsed(.left))
    }

    @MainActor
    @Test func freeControlCollapsesTowardItsNearestEdge() {
        #expect(mode(placement: .free, x: 0.5, y: 0.98) == .collapsed(.top))
        #expect(mode(placement: .free, x: 0.98, y: 0.5) == .collapsed(.right))
        #expect(mode(placement: .free, x: 0.5, y: 0.02) == .collapsed(.bottom))
        #expect(mode(placement: .free, x: 0.02, y: 0.5) == .collapsed(.left))
    }

    @MainActor
    @Test func hoverDragAndListeningKeepTheControlExpanded() {
        #expect(mode(isHovered: true) == .idle)
        #expect(mode(isDragging: true) == .idle)
        #expect(mode(isListening: true) == .listening)
    }

    @MainActor
    @Test func appKitTrackingEventsReachTheHoverCallback() throws {
        let view = FloatingInteractionView(rootView: EmptyView())
        var hoverStates: [Bool] = []
        view.onHoverChanged = { hoverStates.append($0) }
        let entered = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            trackingNumber: 1,
            userData: nil
        ))
        let exited = try #require(NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            trackingNumber: 1,
            userData: nil
        ))

        view.mouseEntered(with: entered)
        view.mouseExited(with: exited)

        #expect(hoverStates == [true, false])
    }

    @MainActor
    @Test func completeFrameAnimationMovesARealPanel() async {
        let panel = NSPanel(
            contentRect: NSRect(x: 40, y: 40, width: 18, height: 58),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        let target = NSRect(x: 40, y: 40, width: 56, height: 56)

        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.01
                panel.animator().setFrame(target, display: true)
            } completionHandler: {
                continuation.resume()
            }
        }

        #expect(panel.frame == target)
    }

    @MainActor
    private func mode(
        isListening: Bool = false,
        isHovered: Bool = false,
        isDragging: Bool = false,
        placement: BarPlacement = .bottom,
        x: Double = 0.5,
        y: Double = 0
    ) -> FloatingBarMode {
        FloatingBarPresentation.mode(
            isListening: isListening,
            isHovered: isHovered,
            isDragging: isDragging,
            placement: placement,
            freeX: x,
            freeY: y
        )
    }

}
