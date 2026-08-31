@preconcurrency import AppKit
@preconcurrency import Combine
import SwiftUI

enum FloatingDockEdge: Equatable {
    case top
    case right
    case bottom
    case left
}

enum FloatingBarMode: Equatable {
    case collapsed(FloatingDockEdge)
    case idle
    case listening

    var baseSize: NSSize {
        switch self {
        case .collapsed(.top), .collapsed(.bottom):
            NSSize(width: 58, height: 18)
        case .collapsed(.left), .collapsed(.right):
            NSSize(width: 18, height: 58)
        case .idle:
            NSSize(width: 56, height: 56)
        case .listening:
            NSSize(width: 430, height: 72)
        }
    }
}

@MainActor
final class FloatingBarPresentation: ObservableObject {
    @Published var mode: FloatingBarMode = .idle

    static func mode(
        isListening: Bool,
        isHovered: Bool,
        isDragging: Bool,
        placement: BarPlacement,
        freeX: Double,
        freeY: Double
    ) -> FloatingBarMode {
        if isListening { return .listening }
        if isHovered || isDragging { return .idle }

        let edge: FloatingDockEdge = switch placement {
        case .top: .top
        case .right: .right
        case .bottom: .bottom
        case .left: .left
        case .free: nearestEdge(x: freeX, y: freeY)
        }
        return .collapsed(edge)
    }

    private static func nearestEdge(x: Double, y: Double) -> FloatingDockEdge {
        let normalizedX = min(max(x, 0), 1)
        let normalizedY = min(max(y, 0), 1)
        let candidates: [(FloatingDockEdge, Double)] = [
            (.top, 1 - normalizedY),
            (.bottom, normalizedY),
            (.left, normalizedX),
            (.right, 1 - normalizedX)
        ]
        return candidates.min { $0.1 < $1.1 }?.0 ?? .bottom
    }
}

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model: AppModel
    private let presentation = FloatingBarPresentation()
    private let snapOverlay = SnapTargetsOverlayController()
    private let recoveryOverlay: InsertionRecoveryOverlayController
    private var cancellables = Set<AnyCancellable>()
    private var isTrackingDrag = false
    private var freeDragWasRequested = false
    private var isPointerInside = false
    private var collapseTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        recoveryOverlay = InsertionRecoveryOverlayController(model: model)
        presentation.mode = FloatingBarPresentation.mode(
            isListening: model.isListening,
            isHovered: false,
            isDragging: false,
            placement: model.barPlacement,
            freeX: model.freeBarX,
            freeY: model.freeBarY
        )
        let size = Self.scaledSize(for: model, mode: presentation.mode)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        let interactionView = FloatingInteractionView(
            rootView: FloatingBar(presentation: presentation).environmentObject(model)
        )
        interactionView.shouldCaptureMouse = { [weak model] in model?.isListening == false }
        interactionView.onSingleMouseDown = { [weak self] event in self?.beginTrackedDrag(with: event) }
        interactionView.onDoubleClick = { [weak self] in self?.openMainApp() }
        interactionView.onHoverChanged = { [weak self] isHovered in self?.setHovered(isHovered) }
        panel.contentView = interactionView

        position(animated: false)
        panel.orderFrontRegardless()
        observePreferences()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.position(animated: false) } }
    }

    private func observePreferences() {
        model.$barPlacement
            .dropFirst()
            .sink { [weak self] placement in self?.refreshPresentation(animated: true, placement: placement) }
            .store(in: &cancellables)

        model.$barScale
            .dropFirst()
            .sink { [weak self] scale in self?.refreshPresentation(animated: true, scale: scale) }
            .store(in: &cancellables)

        model.$state
            .map { state in state == .listening || state == .finishing }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isListening in
                self?.refreshPresentation(animated: true, isListening: isListening)
            }
            .store(in: &cancellables)

        model.$insertionRecovery
            .removeDuplicates()
            .sink { [weak self] recovery in
                guard let self else { return }
                if recovery == nil {
                    recoveryOverlay.hide()
                } else if let screen = activeScreen {
                    recoveryOverlay.show(near: panel.frame, in: screen.visibleFrame)
                }
            }
            .store(in: &cancellables)
    }

    private func position(
        animated: Bool,
        placement placementOverride: BarPlacement? = nil,
        scale scaleOverride: Double? = nil,
        mode modeOverride: FloatingBarMode? = nil
    ) {
        guard let screen = activeScreen else { return }
        let visible = screen.visibleFrame
        let placement = placementOverride ?? model.barPlacement
        let mode = modeOverride ?? presentation.mode
        let size = Self.scaledSize(for: model, scale: scaleOverride, mode: mode)
        let margin = placement == .bottom ? 1.0 : 8.0
        let origin: NSPoint

        switch placement {
        case .bottom:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + margin)
        case .top:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - margin)
        case .left:
            origin = NSPoint(x: visible.minX + margin, y: visible.midY - size.height / 2)
        case .right:
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.midY - size.height / 2)
        case .free:
            let availableWidth = max(visible.width - size.width, 0)
            let availableHeight = max(visible.height - size.height, 0)
            origin = NSPoint(
                x: visible.minX + availableWidth * model.freeBarX,
                y: visible.minY + availableHeight * model.freeBarY
            )
        }

        let frame = NSRect(origin: SnapGeometry.clamped(origin, size: size, in: visible), size: size)
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func refreshPresentation(
        animated: Bool,
        placement placementOverride: BarPlacement? = nil,
        scale scaleOverride: Double? = nil,
        isListening listeningOverride: Bool? = nil
    ) {
        let placement = placementOverride ?? model.barPlacement
        let isListening = listeningOverride ?? model.isListening
        let mode = FloatingBarPresentation.mode(
            isListening: isListening,
            isHovered: isPointerInside,
            isDragging: isTrackingDrag,
            placement: placement,
            freeX: model.freeBarX,
            freeY: model.freeBarY
        )
        presentation.mode = mode
        position(animated: animated, placement: placement, scale: scaleOverride, mode: mode)
    }

    private func setHovered(_ isHovered: Bool) {
        isPointerInside = isHovered
        collapseTask?.cancel()
        collapseTask = nil

        if isHovered {
            refreshPresentation(animated: true)
        } else {
            scheduleCollapse(after: .milliseconds(220))
        }
    }

    private func scheduleCollapse(after delay: Duration) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let pointerIsInside = NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
            isPointerInside = pointerIsInside
            guard !pointerIsInside, !isTrackingDrag, !model.isListening else { return }
            refreshPresentation(animated: true)
        }
    }

    private func beginTrackedDrag(with event: NSEvent) {
        guard !model.isListening else { return }
        let startingMouse = panel.convertPoint(toScreen: event.locationInWindow)
        isTrackingDrag = true
        collapseTask?.cancel()
        collapseTask = nil
        refreshPresentation(animated: false)
        freeDragWasRequested = event.modifierFlags.contains(.command)
        let startingOrigin = panel.frame.origin
        updateSnapPreview()

        while isTrackingDrag,
              let nextEvent = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            freeDragWasRequested = freeDragWasRequested || nextEvent.modifierFlags.contains(.command)
            if nextEvent.type == .leftMouseUp {
                finishTrackedDrag()
                break
            }

            let mouse = panel.convertPoint(toScreen: nextEvent.locationInWindow)
            let proposed = NSPoint(
                x: startingOrigin.x + mouse.x - startingMouse.x,
                y: startingOrigin.y + mouse.y - startingMouse.y
            )
            let screen = screen(containing: mouse) ?? activeScreen
            if let visible = screen?.visibleFrame {
                panel.setFrameOrigin(SnapGeometry.clamped(proposed, size: panel.frame.size, in: visible))
            }
            updateSnapPreview()
        }
    }

    private func updateSnapPreview() {
        guard isTrackingDrag, let screen = activeScreen else { return }
        if freeDragWasRequested {
            snapOverlay.hide()
        } else {
            let slot = SnapGeometry.nearestSlot(to: panel.frame.origin, size: panel.frame.size, in: screen.visibleFrame)
            snapOverlay.show(in: screen.visibleFrame, activeSlot: slot, relativeTo: panel)
        }
    }

    private func finishTrackedDrag() {
        guard isTrackingDrag else { return }
        isTrackingDrag = false
        defer {
            freeDragWasRequested = false
            snapOverlay.hide()
        }
        guard let screen = activeScreen else { return }
        let visible = screen.visibleFrame
        let target: NSPoint
        if freeDragWasRequested {
            target = SnapGeometry.clamped(panel.frame.origin, size: panel.frame.size, in: visible)
        } else {
            let slot = SnapGeometry.nearestSlot(to: panel.frame.origin, size: panel.frame.size, in: visible)
            target = SnapGeometry.origin(for: slot, size: panel.frame.size, in: visible)
        }
        if panel.frame.origin != target, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // animator().setFrameOrigin is silently ignored by NSWindow; only setFrame animates
                panel.animator().setFrame(NSRect(origin: target, size: panel.frame.size), display: true)
            }
        }
        saveFreePosition(target, in: visible)
        scheduleCollapse(after: .milliseconds(320))
    }

    func windowDidMove(_ notification: Notification) {
        updateSnapPreview()
    }

    private func openMainApp() {
        model.selectedSection = .home
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
    }

    private func saveFreePosition(_ origin: NSPoint, in visible: NSRect) {
        let availableWidth = max(visible.width - panel.frame.width, 1)
        let availableHeight = max(visible.height - panel.frame.height, 1)
        model.saveFreeBarPosition(
            x: (origin.x - visible.minX) / availableWidth,
            y: (origin.y - visible.minY) / availableHeight
        )
        if model.barPlacement != .free { model.barPlacement = .free }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private var activeScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) ?? NSScreen.main
    }

    private static func scaledSize(
        for model: AppModel,
        scale scaleOverride: Double? = nil,
        mode: FloatingBarMode
    ) -> NSSize {
        let scale = scaleOverride ?? model.barScale
        let base = mode.baseSize
        return NSSize(width: base.width * scale, height: base.height * scale)
    }

}

@MainActor
private final class InsertionRecoveryOverlayController {
    private let panel: NSPanel

    init(model: AppModel) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 390, height: 190)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: InsertionRecoveryCard().environmentObject(model))
    }

    func show(near floatingFrame: NSRect, in visible: NSRect) {
        let size = panel.frame.size
        let preferredBelow = floatingFrame.minY - size.height - 10
        let preferredAbove = floatingFrame.maxY + 10
        let y = preferredBelow >= visible.minY ? preferredBelow : min(preferredAbove, visible.maxY - size.height)
        let origin = SnapGeometry.clamped(
            NSPoint(x: floatingFrame.midX - size.width / 2, y: y),
            size: size,
            in: visible.insetBy(dx: 8, dy: 8)
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private struct InsertionRecoveryCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let recovery = model.insertionRecovery {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    BrandMark(size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("It appears that it was not pasted in.")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text("Here’s a copy of your transcript from \(recovery.appName).")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.58))
                    }
                    Spacer()
                    Button { model.dismissInsertionRecovery() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white.opacity(0.58))
                }

                Text(recovery.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(CadenceTheme.cream.opacity(0.86))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))

                HStack {
                    Spacer()
                    Button {
                        model.copyInsertionRecovery()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CadenceTheme.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Capsule().fill(CadenceTheme.lime))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(width: 390, height: 190)
            .foregroundStyle(CadenceTheme.cream)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(CadenceTheme.ink.opacity(0.98))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12)))
            )
        }
    }
}

@MainActor
final class FloatingInteractionView<Content: View>: NSView {
    var shouldCaptureMouse: () -> Bool = { true }
    var onSingleMouseDown: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private let hostingView: NSHostingView<Content>
    private var hoverTrackingArea: NSTrackingArea?

    init(rootView: Content) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        shouldCaptureMouse() ? self : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        switch FloatingClickAction(clickCount: event.clickCount) {
        case .open:
            onDoubleClick?()
        case .drag:
            onSingleMouseDown?(event)
        case .ignore:
            break
        }
    }
}

enum FloatingClickAction: Equatable {
    case drag
    case open
    case ignore

    init(clickCount: Int) {
        switch clickCount {
        case 1: self = .drag
        case 2: self = .open
        default: self = .ignore
        }
    }
}

enum SnapSlot: Int, CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

struct SnapGeometry {
    static func nearestSlot(to origin: NSPoint, size: NSSize, in visible: NSRect) -> SnapSlot {
        let proposedCenter = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        return SnapSlot.allCases.min {
            distance(from: proposedCenter, to: center(for: $0, size: size, in: visible)) <
                distance(from: proposedCenter, to: center(for: $1, size: size, in: visible))
        } ?? .bottom
    }

    static func origin(for slot: SnapSlot, size: NSSize, in visible: NSRect) -> NSPoint {
        let inset = 1.0
        let left = visible.minX + inset
        let centerX = visible.midX - size.width / 2
        let right = visible.maxX - size.width - inset
        let bottom = visible.minY + inset
        let middleY = visible.midY - size.height / 2
        let top = visible.maxY - size.height - inset
        let point: NSPoint = switch slot {
        case .topLeft: NSPoint(x: left, y: top)
        case .top: NSPoint(x: centerX, y: top)
        case .topRight: NSPoint(x: right, y: top)
        case .right: NSPoint(x: right, y: middleY)
        case .bottomRight: NSPoint(x: right, y: bottom)
        case .bottom: NSPoint(x: centerX, y: bottom)
        case .bottomLeft: NSPoint(x: left, y: bottom)
        case .left: NSPoint(x: left, y: middleY)
        }
        return clamped(point, size: size, in: visible)
    }

    static func clamped(_ origin: NSPoint, size: NSSize, in frame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, frame.minX), max(frame.minX, frame.maxX - size.width)),
            y: min(max(origin.y, frame.minY), max(frame.minY, frame.maxY - size.height))
        )
    }

    private static func center(for slot: SnapSlot, size: NSSize, in visible: NSRect) -> NSPoint {
        let point = origin(for: slot, size: size, in: visible)
        return NSPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
    }

    private static func distance(from first: NSPoint, to second: NSPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }
}

@MainActor
private final class SnapOverlayState: ObservableObject {
    @Published var activeSlot: SnapSlot = .bottom
}

@MainActor
private final class SnapTargetsOverlayController {
    private let state = SnapOverlayState()
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: SnapTargetsView(state: state))
    }

    func show(in visible: NSRect, activeSlot: SnapSlot, relativeTo floatingPanel: NSPanel) {
        state.activeSlot = activeSlot
        if panel.frame != visible { panel.setFrame(visible, display: true) }
        if !panel.isVisible { panel.order(.below, relativeTo: floatingPanel.windowNumber) }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private struct SnapTargetsView: View {
    @ObservedObject var state: SnapOverlayState

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(SnapSlot.allCases, id: \.rawValue) { slot in
                    target(slot)
                        .position(position(for: slot, in: proxy.size))
                }
            }
        }
    }

    private func position(for slot: SnapSlot, in size: CGSize) -> CGPoint {
        let inset = 46.0
        return switch slot {
        case .topLeft: CGPoint(x: inset, y: inset)
        case .top: CGPoint(x: size.width / 2, y: inset)
        case .topRight: CGPoint(x: size.width - inset, y: inset)
        case .right: CGPoint(x: size.width - inset, y: size.height / 2)
        case .bottomRight: CGPoint(x: size.width - inset, y: size.height - inset)
        case .bottom: CGPoint(x: size.width / 2, y: size.height - inset)
        case .bottomLeft: CGPoint(x: inset, y: size.height - inset)
        case .left: CGPoint(x: inset, y: size.height / 2)
        }
    }

    private func target(_ slot: SnapSlot) -> some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(state.activeSlot == slot ? CadenceTheme.lime.opacity(0.32) : Color.white.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(state.activeSlot == slot ? 0.55 : 0.2), lineWidth: 1)
            )
            .frame(width: 72, height: 78)
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .scaleEffect(state.activeSlot == slot ? 1.06 : 1)
            .animation(.easeOut(duration: 0.12), value: state.activeSlot)
    }
}

struct FloatingBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var presentation: FloatingBarPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch presentation.mode {
            case .listening:
                listeningBar
            case .idle:
                idleLogo
            case let .collapsed(edge):
                collapsedHandle(edge: edge)
            }
        }
        .scaleEffect(model.barScale)
        .frame(
            width: presentation.mode.baseSize.width * model.barScale,
            height: presentation.mode.baseSize.height * model.barScale
        )
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: presentation.mode)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.barScale)
    }

    private var listeningBar: some View {
        HStack(spacing: 10) {
            Button { model.cancelDictation() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.28)))
            }
            .buttonStyle(.plain)

            WaveformMark(level: model.audioLevel, bars: 7)

            Text(model.liveText.isEmpty ? "Listening…" : model.liveText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(model.liveText.isEmpty ? Color.white.opacity(0.48) : CadenceTheme.cream)
                .lineLimit(1)
                .frame(maxWidth: 215, alignment: .leading)
                .contentTransition(.numericText())

            Button { model.stopDictation() } label: {
                Image(systemName: model.state == .finishing ? "ellipsis" : "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CadenceTheme.ink)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(CadenceTheme.cream))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .frame(width: 408, height: 48)
        .background(
            Capsule()
                .fill(CadenceTheme.ink.opacity(0.97))
                .overlay(Capsule().stroke(Color(red: 0.3, green: 0.29, blue: 0.26), lineWidth: 1))
                .shadow(color: .black.opacity(0.24), radius: 16, y: 7)
        )
        .frame(width: 430, height: 72)
    }

    private var idleLogo: some View {
        BrandMark(size: 34)
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            .help("Drag to move · Double-click to open Cadence")
            .frame(width: 56, height: 56)
    }

    private func collapsedHandle(edge: FloatingDockEdge) -> some View {
        ZStack(alignment: alignment(for: edge)) {
            Color.clear
            Capsule()
                .fill(Color(nsColor: .secondaryLabelColor).opacity(0.72))
                .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .frame(
                    width: edge == .left || edge == .right ? 11 : 48,
                    height: edge == .left || edge == .right ? 48 : 11
                )
        }
        .frame(width: presentation.mode.baseSize.width, height: presentation.mode.baseSize.height)
        .help("Hover to reveal Cadence · Drag to move")
        .accessibilityLabel("Cadence dictation control")
    }

    private func alignment(for edge: FloatingDockEdge) -> Alignment {
        switch edge {
        case .top: .top
        case .right: .trailing
        case .bottom: .bottom
        case .left: .leading
        }
    }
}
