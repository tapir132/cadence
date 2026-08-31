@preconcurrency import AppKit
import ApplicationServices
import Foundation

@MainActor
final class KeystrokeInjector {
    var characterDelayMilliseconds = 7.0
    private(set) var hadPostingFailure = false
    private var typingTask: Task<Void, Never>?
    private var pending = ""
    private var drainGeneration = 0

    func beginSession() {
        cancelPending()
        hadPostingFailure = false
    }

    func enqueue(_ text: String) {
        pending += text
        guard typingTask == nil else { return }
        let generation = drainGeneration
        typingTask = Task { [weak self] in await self?.drain(generation: generation) }
    }

    func cancelPending() {
        drainGeneration += 1
        typingTask?.cancel()
        typingTask = nil
        pending = ""
    }

    func waitUntilDrained() async {
        while typingTask != nil || !pending.isEmpty {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    private func drain(generation: Int) async {
        while !pending.isEmpty, !Task.isCancelled {
            let character = pending.removeFirst()
            if !post(character) { hadPostingFailure = true }
            let delay = character.isWhitespace ? characterDelayMilliseconds * 2.2 : characterDelayMilliseconds
            try? await Task.sleep(for: .milliseconds(delay))
        }
        if generation == drainGeneration { typingTask = nil }
    }

    private func post(_ character: Character) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let units = Array(String(character).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
