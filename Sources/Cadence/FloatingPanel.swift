import AppKit
@preconcurrency import Combine
import SwiftUI

@MainActor
final class FloatingPanelController: NSObject, NSWindowDelegate {
    private static let idleBaseSize = NSSize(width: 56, height: 56)
    private static let listeningBaseSize = NSSize(width: 430, height: 72)
    private let panel: NSPanel
    private let model: AppModel
    private let snapOverlay = SnapTargetsOverlayController()
    private var cancellables = Set<AnyCancellable>()
    private var isSystemDragging = false
    private var freeDragWasRequested = false
    private var dragEndTimer: Timer?

    init(model: AppModel) {
        self.model = model
        let size = Self.scaledSize(for: model)
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
        let interactionView = FloatingInteractionView(rootView: FloatingBar().environmentObject(model))
        interactionView.shouldCaptureMouse = { [weak model] in model?.isListening == false }
        interactionView.onSingleMouseDown = { [weak self] event in self?.beginSystemDrag(with: event) }
        interactionView.onDoubleClick = { [weak self] in self?.openMainApp() }
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
            .sink { [weak self] _ in self?.position(animated: true) }
            .store(in: &cancellables)

        model.$barScale
            .dropFirst()
            .sink { [weak self] _ in self?.position(animated: true) }
            .store(in: &cancellables)

        model.$state
            .map { state in state == .listening || state == .finishing }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isListening in
                self?.position(animated: true)
            }
            .store(in: &cancellables)
    }

    private func position(animated: Bool) {
        guard let screen = activeScreen else { return }
        let visible = screen.visibleFrame
        let size = Self.scaledSize(for: model)
        let margin = model.barPlacement == .bottom ? 1.0 : 8.0
        let origin: NSPoint

        switch model.barPlacement {
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

        let frame = NSRect(origin: clamped(origin, size: size, in: visible), size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func beginSystemDrag(with event: NSEvent) {
        guard !model.isListening, !isSystemDragging else { return }
        isSystemDragging = true
        freeDragWasRequested = event.modifierFlags.contains(.command)
        updateSnapPreview()

        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(pollSystemDrag(_:)),
            userInfo: nil,
            repeats: true
        )
        dragEndTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        panel.performDrag(with: event)
    }

    @objc private func pollSystemDrag(_ timer: Timer) {
        guard isSystemDragging else {
            timer.invalidate()
            return
        }
        freeDragWasRequested = freeDragWasRequested || NSEvent.modifierFlags.contains(.command)
        if NSEvent.pressedMouseButtons & 1 == 0 {
            finishSystemDrag()
        }
    }

    private func updateSnapPreview() {
        guard isSystemDragging, let screen = activeScreen else { return }
        if freeDragWasRequested {
            snapOverlay.hide()
        } else {
            let slot = nearestSnapSlot(to: panel.frame.origin, size: panel.frame.size, in: screen.visibleFrame)
            snapOverlay.show(in: screen.visibleFrame, activeSlot: slot, relativeTo: panel)
        }
    }

    private func finishSystemDrag() {
        guard isSystemDragging else { return }
        isSystemDragging = false
        dragEndTimer?.invalidate()
        dragEndTimer = nil
        defer {
            freeDragWasRequested = false
            snapOverlay.hide()
        }
        guard let screen = activeScreen else { return }
        let visible = screen.visibleFrame
        let target: NSPoint
        if freeDragWasRequested {
            target = clamped(panel.frame.origin, size: panel.frame.size, in: visible)
        } else {
            let slot = nearestSnapSlot(to: panel.frame.origin, size: panel.frame.size, in: visible)
            target = snapOrigin(for: slot, size: panel.frame.size, in: visible)
        }
        if panel.frame.origin != target {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(target)
            }
        }
        saveFreePosition(target, in: visible)
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

    private func nearestSnapSlot(to origin: NSPoint, size: NSSize, in visible: NSRect) -> SnapSlot {
        let center = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        return SnapSlot.allCases.min {
            distance(from: center, to: snapCenter(for: $0, size: size, in: visible)) <
                distance(from: center, to: snapCenter(for: $1, size: size, in: visible))
        } ?? .bottom
    }

    private func distance(from first: NSPoint, to second: NSPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }

    private func snapCenter(for slot: SnapSlot, size: NSSize, in visible: NSRect) -> NSPoint {
        let origin = snapOrigin(for: slot, size: size, in: visible)
        return NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    private func snapOrigin(for slot: SnapSlot, size: NSSize, in visible: NSRect) -> NSPoint {
        let inset = 1.0
        let left = visible.minX + inset
        let centerX = visible.midX - size.width / 2
        let right = visible.maxX - size.width - inset
        let bottom = visible.minY + inset
        let middleY = visible.midY - size.height / 2
        let top = visible.maxY - size.height - inset
        let origin: NSPoint
        switch slot {
        case .topLeft: origin = NSPoint(x: left, y: top)
        case .top: origin = NSPoint(x: centerX, y: top)
        case .topRight: origin = NSPoint(x: right, y: top)
        case .right: origin = NSPoint(x: right, y: middleY)
        case .bottomRight: origin = NSPoint(x: right, y: bottom)
        case .bottom: origin = NSPoint(x: centerX, y: bottom)
        case .bottomLeft: origin = NSPoint(x: left, y: bottom)
        case .left: origin = NSPoint(x: left, y: middleY)
        }
        return clamped(origin, size: size, in: visible)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private var activeScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) ?? NSScreen.main
    }

    private func clamped(_ origin: NSPoint, size: NSSize, in frame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, frame.minX), max(frame.minX, frame.maxX - size.width)),
            y: min(max(origin.y, frame.minY), max(frame.minY, frame.maxY - size.height))
        )
    }

    private static func scaledSize(for model: AppModel) -> NSSize {
        let base = model.isListening ? listeningBaseSize : idleBaseSize
        return NSSize(width: base.width * model.barScale, height: base.height * model.barScale)
    }
}

@MainActor
private final class FloatingInteractionView<Content: View>: NSView {
    var shouldCaptureMouse: () -> Bool = { true }
    var onSingleMouseDown: ((NSEvent) -> Void)?
    var onDoubleClick: (() -> Void)?

    private let hostingView: NSHostingView<Content>

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        shouldCaptureMouse() ? self : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else if event.clickCount == 1 {
            onSingleMouseDown?(event)
        }
    }
}

private enum SnapSlot: Int, CaseIterable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
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

    var body: some View {
        HStack(spacing: 10) {
            if model.isListening {
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
            } else {
                BrandMark(size: 34)
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                    .help("Drag to move · Double-click to open Cadence")
            }
        }
        .padding(.horizontal, model.isListening ? 9 : 10)
        .frame(width: model.isListening ? 408 : 42, height: model.isListening ? 48 : 42)
        .background(
            Group {
                if model.isListening {
                    Capsule()
                        .fill(CadenceTheme.ink.opacity(0.97))
                        .overlay(Capsule().stroke(Color(red: 0.3, green: 0.29, blue: 0.26), lineWidth: 1))
                        .shadow(color: .black.opacity(0.24), radius: 16, y: 7)
                }
            }
        )
        .frame(width: model.isListening ? 430 : 56, height: model.isListening ? 72 : 56)
        .scaleEffect(model.barScale)
        .frame(
            width: (model.isListening ? 430 : 56) * model.barScale,
            height: (model.isListening ? 72 : 56) * model.barScale
        )
        .contentShape(Rectangle())
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.isListening)
        .animation(.easeOut(duration: 0.18), value: model.barScale)
    }

}
