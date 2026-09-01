import AppKit
import Carbon.HIToolbox
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
    /// `nil` is a modifier-only chord such as ⌃⌥, fired when it is released.
    var keyCode: UInt16?
    var modifiersRawValue: UInt
    var keyLabel: String

    static let standard = ShortcutBinding(
        keyCode: 49,
        modifiersRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue,
        keyLabel: "Space"
    )

    /// Caps Lock, Fn, and the numeric-pad flag describe keyboard state, not a
    /// shortcut. Comparing them made ⌃⌥Space fail whenever Caps Lock was on.
    static let shortcutModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    static let functionKeyLabels: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20"
    ]

    var isModifierOnly: Bool { keyCode == nil }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue).intersection(Self.shortcutModifiers)
    }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        return flags
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

    /// Function keys are valid on their own; any other key needs ⌃, ⌥, or ⌘ so
    /// ordinary typing can never trigger dictation.
    static func from(_ event: NSEvent) -> ShortcutBinding? {
        let modifiers = event.modifierFlags.intersection(shortcutModifiers)
        let isFunctionKey = functionKeyLabels[event.keyCode] != nil
        guard isFunctionKey || hasPrimaryModifier(modifiers) else { return nil }
        return ShortcutBinding(
            keyCode: event.keyCode,
            modifiersRawValue: modifiers.rawValue,
            keyLabel: label(for: event)
        )
    }

    /// Shift alone is tapped constantly while typing, so a chord needs ⌃, ⌥, or ⌘.
    static func modifierOnly(_ flags: NSEvent.ModifierFlags) -> ShortcutBinding? {
        let modifiers = flags.intersection(shortcutModifiers)
        guard hasPrimaryModifier(modifiers) else { return nil }
        return ShortcutBinding(keyCode: nil, modifiersRawValue: modifiers.rawValue, keyLabel: "")
    }

    private static func hasPrimaryModifier(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection([.control, .option, .command]).isEmpty
    }

    private static func label(for event: NSEvent) -> String {
        let special: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End",
            121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let label = special[event.keyCode] ?? functionKeyLabels[event.keyCode] { return label }
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

/// Recording reads keys through a local event monitor instead of first-responder
/// `keyDown`, so menu key equivalents, SwiftUI focus, and the enclosing scroll
/// view never see the pressed keys. The global hot key is suspended meanwhile so
/// re-recording the current shortcut cannot toggle dictation. Modifier-only
/// chords are recorded when the last modifier is released without any other key.
final class ShortcutRecorderNSView: NSView {
    var onShortcut: ((ShortcutBinding) -> Void)?
    var shortcut: ShortcutBinding = .standard { didSet { updateTitle() } }
    private let button = NSButton(title: "", target: nil, action: nil)
    private var monitor: Any?
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var isRecording: Bool { monitor != nil }

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

    @objc private func beginRecording() {
        guard !isRecording else { return }
        button.title = "Press shortcut…"
        heldModifiers = []
        GlobalHotKey.shared.isSuspended = true
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .flagsChanged:
                let current = event.modifierFlags.intersection(ShortcutBinding.shortcutModifiers)
                if !current.isEmpty {
                    heldModifiers.formUnion(current)
                } else if !heldModifiers.isEmpty {
                    let chord = heldModifiers
                    heldModifiers = []
                    accept(ShortcutBinding.modifierOnly(chord))
                }
                return event
            case .keyDown:
                heldModifiers = []
                if event.keyCode == 53 {
                    finishRecording()
                } else {
                    accept(ShortcutBinding.from(event))
                }
                return nil
            default:
                finishRecording()
                return event
            }
        }
    }

    private func accept(_ value: ShortcutBinding?) {
        guard let value else {
            NSSound.beep()
            button.title = "Add ⌃⌥⌘ or F-key"
            return
        }
        shortcut = value
        onShortcut?(value)
        finishRecording()
    }

    private func finishRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        GlobalHotKey.shared.isSuspended = false
        updateTitle()
    }

    private func updateTitle() {
        guard !isRecording else { return }
        button.title = shortcut.displayText
    }
}
