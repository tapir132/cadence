import AppKit
import Carbon.HIToolbox
import SwiftUI

enum RecognitionProfile: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case fast
    case accurate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: "Fast"
        case .accurate: "Accurate"
        }
    }

    var detail: String {
        switch self {
        case .fast: "~320 ms · best for immediate typing"
        case .accurate: "~1.1 s · more context for difficult speech"
        }
    }
}

struct TranscriptDeliveryPreferences: Equatable, Sendable {
    static let defaults = TranscriptDeliveryPreferences(
        speechCleanupEnabled: false,
        deepEditingEnabled: false,
        typingBufferEnabled: false,
        characterPlaybackEnabled: false,
        characterPlaybackWordsPerMinute: CharacterPlaybackPacing.defaultWordsPerMinute,
        characterPlaybackRhythm: .steady
    )

    let speechCleanupEnabled: Bool
    let deepEditingEnabled: Bool
    let typingBufferEnabled: Bool
    let characterPlaybackEnabled: Bool
    let characterPlaybackWordsPerMinute: Double
    let characterPlaybackRhythm: CharacterPlaybackRhythm

    init(
        speechCleanupEnabled: Bool,
        deepEditingEnabled: Bool,
        typingBufferEnabled: Bool,
        characterPlaybackEnabled: Bool,
        characterPlaybackWordsPerMinute: Double,
        characterPlaybackRhythm: CharacterPlaybackRhythm
    ) {
        self.speechCleanupEnabled = speechCleanupEnabled
        self.deepEditingEnabled = deepEditingEnabled
        self.typingBufferEnabled = typingBufferEnabled
        self.characterPlaybackEnabled = characterPlaybackEnabled
        self.characterPlaybackWordsPerMinute = CharacterPlaybackPacing(
            wordsPerMinute: characterPlaybackWordsPerMinute
        ).wordsPerMinute
        self.characterPlaybackRhythm = characterPlaybackRhythm
    }

    static func load(from defaults: UserDefaults) -> TranscriptDeliveryPreferences {
        let rhythm = defaults.string(forKey: "characterPlaybackRhythm")
            .flatMap(CharacterPlaybackRhythm.init(rawValue:))
            ?? (defaults.bool(forKey: "characterPlaybackTimingVariationEnabled")
                ? .natural
                : .steady)
        return TranscriptDeliveryPreferences(
            speechCleanupEnabled: defaults.bool(forKey: "speechCleanupEnabled"),
            deepEditingEnabled: defaults.bool(forKey: "deepEditingEnabled"),
            typingBufferEnabled: defaults.bool(forKey: "typingBufferEnabled"),
            characterPlaybackEnabled: defaults.bool(forKey: "characterPlaybackEnabled"),
            characterPlaybackWordsPerMinute: defaults.object(
                forKey: "characterPlaybackWordsPerMinute"
            ) as? Double ?? Self.defaults.characterPlaybackWordsPerMinute,
            characterPlaybackRhythm: rhythm
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(speechCleanupEnabled, forKey: "speechCleanupEnabled")
        defaults.set(deepEditingEnabled, forKey: "deepEditingEnabled")
        defaults.set(typingBufferEnabled, forKey: "typingBufferEnabled")
        defaults.set(characterPlaybackEnabled, forKey: "characterPlaybackEnabled")
        defaults.set(
            characterPlaybackWordsPerMinute,
            forKey: "characterPlaybackWordsPerMinute"
        )
        defaults.set(characterPlaybackRhythm.rawValue, forKey: "characterPlaybackRhythm")
        // Keep the old boolean coherent so downgrading does not unexpectedly
        // discard a person's preference.
        defaults.set(
            characterPlaybackRhythm != .steady,
            forKey: "characterPlaybackTimingVariationEnabled"
        )
    }
}

struct DictationConfiguration: Equatable, Sendable {
    let recognitionProfile: RecognitionProfile
    let delivery: TranscriptDeliveryPreferences
}

/// Coherent starting points for the growing set of recognition and delivery
/// controls. `custom` is derived whenever a user changes any advanced value;
/// it is not a separate persisted flag that can drift away from the settings.
enum DictationProfile: String, CaseIterable, Identifiable, Sendable {
    case quick
    case normal
    case essay
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: "Quick"
        case .normal: "Normal"
        case .essay: "Essay"
        case .custom: "Custom"
        }
    }

    var detail: String {
        switch self {
        case .quick:
            "For short replies, commands, and forms. Inserts completed chunks immediately, with no extra cleanup or pacing delay."
        case .normal:
            "For messages, notes, and everyday dictation. Cleans clear fillers and waits briefly for stable words, then inserts complete chunks."
        case .essay:
            "For long-form writing. Uses more speech context, deeper end editing, and character-paced delivery that finishes after you release the shortcut."
        case .custom:
            "Your Advanced settings do not match a built-in profile."
        }
    }

    var configuration: DictationConfiguration? {
        switch self {
        case .quick:
            DictationConfiguration(
                recognitionProfile: .fast,
                delivery: TranscriptDeliveryPreferences(
                    speechCleanupEnabled: false,
                    deepEditingEnabled: false,
                    typingBufferEnabled: false,
                    characterPlaybackEnabled: false,
                    characterPlaybackWordsPerMinute: 120,
                    characterPlaybackRhythm: .steady
                )
            )
        case .normal:
            DictationConfiguration(
                recognitionProfile: .fast,
                delivery: TranscriptDeliveryPreferences(
                    speechCleanupEnabled: true,
                    deepEditingEnabled: false,
                    typingBufferEnabled: true,
                    characterPlaybackEnabled: false,
                    characterPlaybackWordsPerMinute: 120,
                    characterPlaybackRhythm: .steady
                )
            )
        case .essay:
            DictationConfiguration(
                recognitionProfile: .accurate,
                delivery: TranscriptDeliveryPreferences(
                    speechCleanupEnabled: true,
                    deepEditingEnabled: true,
                    typingBufferEnabled: true,
                    characterPlaybackEnabled: true,
                    characterPlaybackWordsPerMinute: 100,
                    characterPlaybackRhythm: .natural
                )
            )
        case .custom:
            nil
        }
    }

    static var presets: [DictationProfile] {
        allCases.filter { $0 != .custom }
    }

    static func matching(_ configuration: DictationConfiguration) -> DictationProfile {
        presets.first { profile in
            guard let preset = profile.configuration else { return false }
            let expected = preset.delivery
            let actual = configuration.delivery
            // Pace and rhythm are Essay customizations. They are irrelevant to
            // the chunked Quick and Normal profiles and should never make a
            // recognizable profile appear as Custom.
            return preset.recognitionProfile == configuration.recognitionProfile
                && expected.speechCleanupEnabled == actual.speechCleanupEnabled
                && expected.deepEditingEnabled == actual.deepEditingEnabled
                && expected.typingBufferEnabled == actual.typingBufferEnabled
                && expected.characterPlaybackEnabled == actual.characterPlaybackEnabled
        } ?? .custom
    }
}

/// A three-step view over the two cleanup switches. Quick, Normal, and Essay
/// map onto None, Light, and Medium, so this never conflicts with a profile.
enum AutoCleanupLevel: String, CaseIterable, Identifiable, Sendable {
    case none
    case light
    case medium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .light: "Light"
        case .medium: "Medium"
        }
    }

    var detail: String {
        switch self {
        case .none: "Types exactly what you said, including vocal pauses and restarts"
        case .light: "Removes vocal pauses and detached asides before words appear"
        case .medium: "Also repairs clear restarts and false sentence breaks after you finish"
        }
    }

    var sample: String {
        switch self {
        case .none:
            "So there needs to be, um, there needs to be a setting for this. Because my Apple dictation. Was messing that up."
        case .light:
            "So there needs to be there needs to be a setting for this. Because my Apple dictation. Was messing that up."
        case .medium:
            "So there needs to be a setting for this. Because my Apple dictation was messing that up."
        }
    }

    init(speechCleanupEnabled: Bool, deepEditingEnabled: Bool) {
        self = deepEditingEnabled ? .medium : (speechCleanupEnabled ? .light : .none)
    }

    var speechCleanupEnabled: Bool { self != .none }
    var deepEditingEnabled: Bool { self == .medium }
}

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
