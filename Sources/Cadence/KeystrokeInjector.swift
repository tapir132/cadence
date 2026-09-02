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

struct CharacterPlaybackPacing: Equatable, Sendable {
    static let wordsPerMinuteRange = 40.0...160.0
    static let defaultWordsPerMinute = 120.0

    let wordsPerMinute: Double
    let timingVariationEnabled: Bool

    init(
        wordsPerMinute: Double = defaultWordsPerMinute,
        timingVariationEnabled: Bool = false
    ) {
        self.wordsPerMinute = min(
            max(wordsPerMinute, Self.wordsPerMinuteRange.lowerBound),
            Self.wordsPerMinuteRange.upperBound
        )
        self.timingVariationEnabled = timingVariationEnabled
    }

    /// Typing-speed WPM conventionally treats five characters, including
    /// spaces, as one word. Variation is symmetric, so the selected WPM remains
    /// the long-run average instead of becoming a hidden speed boost.
    func intervalMilliseconds(randomUnit: Double = 0.5) -> Double {
        let base = 60_000 / (wordsPerMinute * 5)
        guard timingVariationEnabled else { return base }
        let unit = min(max(randomUnit, 0), 1)
        return base * (0.85 + (unit * 0.30))
    }

    func interval(randomUnit: Double = 0.5) -> Duration {
        .milliseconds(Int64(intervalMilliseconds(randomUnit: randomUnit).rounded()))
    }
}

enum TextDeliveryMode: Equatable, Sendable {
    case chunked
    case characterByCharacter(CharacterPlaybackPacing)

    func units(for text: String) -> [String] {
        switch self {
        case .chunked:
            [text]
        case .characterByCharacter:
            text.map(String.init)
        }
    }
}

enum TextRewriteResult: Equatable {
    case applied
    case skipped
    case failed
}

/// Inserts committed text with standard paste operations, either as its native
/// delta or one complete grapheme at a time. Apple documents that applications
/// may ignore Unicode text attached to synthetic key events, so both modes keep
/// the dependable physical Command-V delivery mechanism.
@MainActor
final class KeystrokeInjector {
    private(set) var hadPostingFailure = false
    private var insertionTask: Task<Void, Never>?
    private var pending: [String] = []
    private var nextPendingIndex = 0
    private var expectedTarget: TextInsertionSnapshot?
    private var deliveryMode: TextDeliveryMode = .chunked
    private var drainGeneration = 0

    private enum CharacterPasteAcknowledgment {
        case confirmed
        case unchanged
        case unavailable
        case failed
    }

    func beginSession(
        target: TextInsertionSnapshot?,
        deliveryMode: TextDeliveryMode = .chunked
    ) {
        cancelPending()
        expectedTarget = target
        self.deliveryMode = deliveryMode
        hadPostingFailure = false
    }

    func enqueue(_ text: String) {
        guard !text.isEmpty else { return }
        pending.append(contentsOf: deliveryMode.units(for: text))
        guard insertionTask == nil else { return }
        let generation = drainGeneration
        insertionTask = Task { [weak self] in await self?.drain(generation: generation) }
    }

    func cancelPending() {
        drainGeneration += 1
        insertionTask?.cancel()
        insertionTask = nil
        pending.removeAll(keepingCapacity: true)
        nextPendingIndex = 0
        expectedTarget = nil
    }

    func waitUntilDrained() async {
        while insertionTask != nil || nextPendingIndex < pending.count {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(12))
        }
    }

    /// Replaces only the text inserted by this session. Selection is prepared
    /// through Accessibility after proving the document and cursor still match;
    /// the replacement itself uses the editor's normal Command-V path.
    func replaceInsertedText(
        _ insertedText: String,
        with replacement: String
    ) async -> TextRewriteResult {
        guard insertedText != replacement else { return .skipped }
        await waitUntilDrained()
        guard !Task.isCancelled,
              !replacement.isEmpty,
              let expectedTarget,
              TextInsertionVerifier.selectInsertedText(
                expectedTarget,
                insertedText: insertedText
              ) else { return .skipped }

        guard paste(replacement, expectedTarget: expectedTarget) else {
            return TextInsertionVerifier.restoreInsertionPoint(
                expectedTarget,
                insertedText: insertedText
            ) ? .skipped : recordRewriteFailure()
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(800))
        while clock.now < deadline, !Task.isCancelled {
            guard TextInsertionVerifier.matchesCurrentTarget(expectedTarget) else {
                return recordRewriteFailure()
            }
            if TextInsertionVerifier.hasExactInsertedText(
                expectedTarget,
                insertedText: replacement
            ) {
                return .applied
            }
            try? await Task.sleep(for: .milliseconds(12))
        }

        if TextInsertionVerifier.restoreInsertionPoint(
            expectedTarget,
            insertedText: insertedText
        ) {
            return .skipped
        }
        return recordRewriteFailure()
    }

    private func recordRewriteFailure() -> TextRewriteResult {
        hadPostingFailure = true
        return .failed
    }

    private func drain(generation: Int) async {
        while let text = dequeue(), !Task.isCancelled {
            let delivered: Bool
            switch deliveryMode {
            case .chunked:
                delivered = paste(text, expectedTarget: expectedTarget)
                if delivered {
                    // Command-V is delivered asynchronously. Keep the queue
                    // serialized so a later paste cannot replace the pasteboard
                    // before the target has consumed this one.
                    try? await Task.sleep(for: .milliseconds(120))
                }
            case let .characterByCharacter(pacing):
                delivered = await deliverCharacter(text, pacing: pacing)
            }

            guard delivered else {
                hadPostingFailure = true
                pending.removeAll(keepingCapacity: true)
                nextPendingIndex = 0
                break
            }
        }
        if generation == drainGeneration { insertionTask = nil }
    }

    private func dequeue() -> String? {
        guard nextPendingIndex < pending.count else {
            pending.removeAll(keepingCapacity: true)
            nextPendingIndex = 0
            return nil
        }
        let value = pending[nextPendingIndex]
        nextPendingIndex += 1
        if nextPendingIndex > 1_024, nextPendingIndex * 2 > pending.count {
            pending.removeFirst(nextPendingIndex)
            nextPendingIndex = 0
        }
        return value
    }

    private func deliverCharacter(
        _ text: String,
        pacing: CharacterPlaybackPacing
    ) async -> Bool {
        let interval = pacing.interval(
            randomUnit: pacing.timingVariationEnabled ? .random(in: 0...1) : 0.5
        )
        for attempt in 0..<3 {
            let originalSelection = expectedTarget.flatMap(TextInsertionVerifier.currentSelection)
            let startedAt = ContinuousClock.now
            guard paste(text, expectedTarget: expectedTarget) else { return false }

            switch await waitForCharacterPaste(
                text,
                originalSelection: originalSelection,
                startedAt: startedAt,
                interval: interval
            ) {
            case .confirmed, .unavailable:
                return true
            case .unchanged where attempt < 2:
                continue
            case .unchanged, .failed:
                return false
            }
        }
        return false
    }

    /// Accessible editors acknowledge each paste by advancing their insertion
    /// point. A missing V event therefore retries the same grapheme instead of
    /// silently dropping it. Opaque editors retain the conservative timeout.
    private func waitForCharacterPaste(
        _ text: String,
        originalSelection: CFRange?,
        startedAt: ContinuousClock.Instant,
        interval: Duration
    ) async -> CharacterPasteAcknowledgment {
        let clock = ContinuousClock()
        let earliestNextPaste = startedAt.advanced(by: interval)
        let acknowledgmentDeadline = startedAt.advanced(by: .milliseconds(400))

        if let originalSelection, let expectedTarget {
            let expectedLocation = originalSelection.location + text.utf16.count
            var lastObservedSelection: CFRange?
            while clock.now < acknowledgmentDeadline, !Task.isCancelled {
                guard TextInsertionVerifier.matchesCurrentTarget(expectedTarget) else {
                    return .failed
                }
                if let current = TextInsertionVerifier.currentSelection(expectedTarget) {
                    lastObservedSelection = current
                    if current.location >= expectedLocation, current.length == 0 {
                        await sleep(until: earliestNextPaste, clock: clock)
                        return .confirmed
                    }
                    if current.location != originalSelection.location
                        || current.length != originalSelection.length {
                        return .failed
                    }
                }
                try? await Task.sleep(for: .milliseconds(6))
            }
            if let current = TextInsertionVerifier.currentSelection(expectedTarget),
               current.location >= expectedLocation,
               current.length == 0 {
                await sleep(until: earliestNextPaste, clock: clock)
                return .confirmed
            }
            return lastObservedSelection == nil ? .unavailable : .unchanged
        } else {
            let opaqueEditorDelay = max(interval, .milliseconds(120))
            await sleep(until: startedAt.advanced(by: opaqueEditorDelay), clock: clock)
            return .unavailable
        }
    }

    private func sleep(until instant: ContinuousClock.Instant, clock: ContinuousClock) async {
        let remaining = clock.now.duration(to: instant)
        if remaining > .zero { try? await Task.sleep(for: remaining) }
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
        // Dictation text should not make a per-character trip through Universal
        // Clipboard while character playback is active.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
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
