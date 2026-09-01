@preconcurrency import AppKit
import ApplicationServices
import Foundation

/// A source marker lets Cadence distinguish its own synthetic paste keystrokes
/// from real modifier changes. This matters for modifier-only hold-to-talk
/// shortcuts: the synthetic Command key must not look like the user released
/// Option or Control.
enum CadenceSyntheticEvent {
    static let pasteCommandMarker: Int64 = 0x4341_4445_4E43_4556 // "CADENCEV"

    static func markAsPasteCommand(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: pasteCommandMarker)
    }

    static func isPasteCommand(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == pasteCommandMarker
    }
}

/// Inserts each completed live-text delta as one standard paste operation. Apple
/// documents that applications may ignore Unicode text attached to synthetic
/// key events, so Cadence does not use direct per-character CGEvents as its
/// delivery mechanism.
@MainActor
final class KeystrokeInjector {
    private(set) var hadPostingFailure = false
    private var insertionTask: Task<Void, Never>?
    private var pending: [String] = []
    private var expectedTarget: TextInsertionSnapshot?
    private var drainGeneration = 0

    func beginSession(target: TextInsertionSnapshot?) {
        cancelPending()
        expectedTarget = target
        hadPostingFailure = false
    }

    func enqueue(_ text: String) {
        guard !text.isEmpty else { return }
        pending.append(text)
        guard insertionTask == nil else { return }
        let generation = drainGeneration
        insertionTask = Task { [weak self] in await self?.drain(generation: generation) }
    }

    func cancelPending() {
        drainGeneration += 1
        insertionTask?.cancel()
        insertionTask = nil
        pending.removeAll(keepingCapacity: true)
        expectedTarget = nil
    }

    func waitUntilDrained() async {
        while insertionTask != nil || !pending.isEmpty {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    private func drain(generation: Int) async {
        while !pending.isEmpty, !Task.isCancelled {
            let text = pending.removeFirst()
            if !paste(text, expectedTarget: expectedTarget) { hadPostingFailure = true }
            // Command-V is delivered asynchronously. Keep the queue serialized
            // so a later paste cannot replace the pasteboard before the target
            // has consumed this one.
            try? await Task.sleep(for: .milliseconds(120))
        }
        if generation == drainGeneration { insertionTask = nil }
    }

    private func paste(_ text: String, expectedTarget: TextInsertionSnapshot?) -> Bool {
        // Leave the transcript on the clipboard if a target could not be
        // captured or focus changed. That fails closed instead of sending
        // private dictation into a different window.
        guard AXIsProcessTrusted(), let expectedTarget,
              TextInsertionVerifier.matchesCurrentTarget(expectedTarget) else {
            _ = Self.write(text, to: .general)
            return false
        }
        guard Self.write(text, to: .general),
              let events = Self.pasteCommandEvents() else { return false }

        for (index, event) in events.enumerated() {
            // Clipboard ownership and the Command key-down are separate OS
            // operations. Revalidate at the last possible moment before V
            // makes the private transcript visible to another process.
            if index == 1, !TextInsertionVerifier.matchesCurrentTarget(expectedTarget) {
                events[3].post(tap: .cghidEventTap)
                return false
            }
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    static func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        pasteboard.prepareForNewContents(with: [])
        return pasteboard.writeObjects([item])
    }

    /// Posts a complete physical Command+V sequence. Explicit Command key-down
    /// and key-up events are more dependable after sleep than flagging V alone.
    nonisolated static func pasteCommandEvents() -> [CGEvent]? {
        let source = CGEventSource(stateID: .hidSystemState)
        let steps: [(key: CGKeyCode, isDown: Bool, flags: CGEventFlags)] = [
            (0x37, true, .maskCommand),
            (0x09, true, .maskCommand),
            (0x09, false, .maskCommand),
            (0x37, false, [])
        ]
        let events = steps.compactMap { step -> CGEvent? in
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: step.key,
                keyDown: step.isDown
            ) else { return nil }
            event.flags = step.flags
            CadenceSyntheticEvent.markAsPasteCommand(event)
            return event
        }
        return events.count == steps.count ? events : nil
    }
}
