@preconcurrency import AppKit
import ApplicationServices
import Foundation

@MainActor
final class KeystrokeInjector {
    var characterDelayMilliseconds = 7.0
    private var typingTask: Task<Void, Never>?
    private var pending = ""

    func enqueue(_ text: String) {
        pending += text
        guard typingTask == nil else { return }
        typingTask = Task { [weak self] in await self?.drain() }
    }

    func cancelPending() {
        typingTask?.cancel()
        typingTask = nil
        pending = ""
    }

    private func drain() async {
        while !pending.isEmpty, !Task.isCancelled {
            let character = pending.removeFirst()
            post(character)
            let delay = character.isWhitespace ? characterDelayMilliseconds * 2.2 : characterDelayMilliseconds
            try? await Task.sleep(for: .milliseconds(delay))
        }
        typingTask = nil
    }

    private func post(_ character: Character) {
        guard AXIsProcessTrusted() else { return }
        let units = Array(String(character).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
