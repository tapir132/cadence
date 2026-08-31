import AppKit
import SwiftUI

enum BarPlacement: String, CaseIterable, Codable, Identifiable {
    case bottom
    case top
    case left
    case right
    case free

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: "Bottom"
        case .top: "Top"
        case .left: "Left"
        case .right: "Right"
        case .free: "Free"
        }
    }

    var icon: String {
        switch self {
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .free: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

struct ShortcutBinding: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiersRawValue: UInt
    var keyLabel: String

    static let standard = ShortcutBinding(
        keyCode: 49,
        modifiersRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue,
        keyLabel: "Space"
    )

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue).intersection(.deviceIndependentFlagsMask)
    }

    var displayText: String {
        modifierGlyphs + keyLabel
    }

    var modifierGlyphs: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode &&
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers
    }

    static func from(_ event: NSEvent) -> ShortcutBinding? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.intersection([.control, .option, .command]).isEmpty else { return nil }
        return ShortcutBinding(
            keyCode: event.keyCode,
            modifiersRawValue: modifiers.rawValue,
            keyLabel: label(for: event)
        )
    }

    private static func label(for event: NSEvent) -> String {
        let special: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End",
            121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let label = special[event.keyCode] { return label }
        let functionKeys: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        if let label = functionKeys[event.keyCode] { return label }
        return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: ShortcutBinding

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onShortcut = { value in
            context.coordinator.parent.shortcut = value
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        context.coordinator.parent = self
        nsView.shortcut = shortcut
    }

    final class Coordinator {
        var parent: ShortcutRecorder
        init(_ parent: ShortcutRecorder) { self.parent = parent }
    }
}

final class ShortcutRecorderNSView: NSView {
    var onShortcut: ((ShortcutBinding) -> Void)?
    var shortcut: ShortcutBinding = .standard { didSet { updateTitle() } }
    private let button = NSButton(title: "", target: nil, action: nil)
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 148, height: 32) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.bezelStyle = .recessed
        button.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        button.target = self
        button.action = #selector(beginRecording)
        addSubview(button)
        updateTitle()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() { button.frame = bounds }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        if event.keyCode == 53 {
            finishRecording()
            return
        }
        guard let value = ShortcutBinding.from(event) else {
            NSSound.beep()
            button.title = "Add ⌃, ⌥, or ⌘"
            return
        }
        shortcut = value
        onShortcut?(value)
        finishRecording()
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    @objc private func beginRecording() {
        isRecording = true
        button.title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    private func finishRecording() {
        isRecording = false
        updateTitle()
    }

    private func updateTitle() {
        guard !isRecording else { return }
        button.title = shortcut.displayText
    }
}
