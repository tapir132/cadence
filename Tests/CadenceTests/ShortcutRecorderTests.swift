import AppKit
import SwiftUI
import Testing
@testable import Cadence

@MainActor
private final class ShortcutHolder: ObservableObject {
    @Published var shortcut = ShortcutBinding.standard
}

private struct RecorderHost: View {
    @ObservedObject var holder: ShortcutHolder

    var body: some View {
        ScrollView {
            ShortcutRecorder(shortcut: $holder.shortcut).frame(width: 148, height: 32)
        }
    }
}

/// Drives the real recorder inside an `NSHostingView`-backed window, the way
/// Settings hosts it, and delivers key events through `NSApplication`.
@MainActor
@Suite(.serialized)
struct ShortcutRecorderTests {
    private func firstView<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(of: type, in: subview) { return match }
        }
        return nil
    }

    private func keyDown(code: UInt16, flags: NSEvent.ModifierFlags, characters: String, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
    }

    private func makeHostedRecorder() throws -> (NSWindow, ShortcutHolder, NSButton) {
        _ = NSApplication.shared
        let holder = ShortcutHolder()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RecorderHost(holder: holder))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let recorder = try #require(firstView(of: ShortcutRecorderNSView.self, in: window.contentView!))
        let button = try #require(firstView(of: NSButton.self, in: recorder))
        return (window, holder, button)
    }

    @Test func recorderCapturesBareFunctionKey() throws {
        let (window, holder, button) = try makeHostedRecorder()
        defer { window.close() }
        button.performClick(nil)
        #expect(button.title == "Press shortcut…")

        NSApp.sendEvent(try keyDown(code: 96, flags: .function, characters: "\u{F708}", window: window))

        #expect(holder.shortcut.keyCode == 96)
        #expect(holder.shortcut.displayText == "F5")
        #expect(button.title == "F5")
    }

    @Test func recorderCapturesModifierComboAndIgnoresCapsLock() throws {
        let (window, holder, button) = try makeHostedRecorder()
        defer { window.close() }
        button.performClick(nil)

        NSApp.sendEvent(try keyDown(code: 2, flags: [.command, .shift, .capsLock], characters: "D", window: window))

        #expect(holder.shortcut.keyCode == 2)
        #expect(holder.shortcut.displayText == "⇧⌘D")
        #expect(holder.shortcut.modifiers == [.command, .shift])
    }

    @Test func recorderRejectsPlainKeysAndCancelsOnEscape() throws {
        let (window, holder, button) = try makeHostedRecorder()
        defer { window.close() }
        button.performClick(nil)

        NSApp.sendEvent(try keyDown(code: 2, flags: [], characters: "d", window: window))
        #expect(holder.shortcut == .standard)
        #expect(button.title == "Add ⌃⌥⌘ or F-key")

        NSApp.sendEvent(try keyDown(code: 53, flags: [], characters: "\u{1B}", window: window))
        #expect(holder.shortcut == .standard)
        #expect(button.title == "⌃⌥Space")
    }

    @Test func recordingSuspendsTheGlobalHotKeyUntilFinished() throws {
        let hotKey = GlobalHotKey.shared
        hotKey.binding = .standard
        defer { hotKey.binding = nil }
        #expect(hotKey.isRegistered)

        let (window, holder, button) = try makeHostedRecorder()
        defer { window.close() }
        button.performClick(nil)
        #expect(!hotKey.isRegistered)

        NSApp.sendEvent(try keyDown(code: 96, flags: .function, characters: "\u{F708}", window: window))
        #expect(holder.shortcut.displayText == "F5")
        #expect(hotKey.isRegistered)
    }
}
