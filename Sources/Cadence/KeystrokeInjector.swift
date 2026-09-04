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

enum CharacterPlaybackRhythm: String, CaseIterable, Codable, Identifiable, Sendable {
    case steady
    case natural
    case expressive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steady: "Steady"
        case .natural: "Natural"
        case .expressive: "Expressive"
        }
    }

    var detail: String {
        switch self {
        case .steady:
            "Even intervals with no random variation."
        case .natural:
            "Mild variation with brief pauses between words and after punctuation."
        case .expressive:
            "Wider variation with more noticeable phrase and sentence pauses."
        }
    }

    fileprivate var jitter: Double {
        switch self {
        case .steady: 0
        case .natural: 0.12
        case .expressive: 0.25
        }
    }

    fileprivate func boundaryMultiplier(after character: Character?) -> Double {
        guard let character else { return 1 }
        switch self {
        case .steady:
            return 1
        case .natural:
            if character == "\n" { return 2.4 }
            if ".!?".contains(character) { return 1.8 }
            if ",;:".contains(character) { return 1.35 }
            if character.isWhitespace { return 1.2 }
            // Four regular characters and one word boundary still average to
            // the selected five-character WPM convention.
            return 0.95
        case .expressive:
            if character == "\n" { return 3 }
            if ".!?".contains(character) { return 2.3 }
            if ",;:".contains(character) { return 1.6 }
            if character.isWhitespace { return 1.4 }
            return 0.9
        }
    }
}

struct CharacterPlaybackPacing: Equatable, Sendable {
    static let wordsPerMinuteRange = 40.0...160.0
    static let defaultWordsPerMinute = 120.0

    let wordsPerMinute: Double
    let rhythm: CharacterPlaybackRhythm

    init(
        wordsPerMinute: Double = defaultWordsPerMinute,
        rhythm: CharacterPlaybackRhythm = .steady
    ) {
        self.wordsPerMinute = min(
            max(wordsPerMinute, Self.wordsPerMinuteRange.lowerBound),
            Self.wordsPerMinuteRange.upperBound
        )
        self.rhythm = rhythm
    }

    /// Typing-speed WPM conventionally treats five characters, including
    /// spaces, as one word. Non-steady rhythms keep ordinary word timing near
    /// that average while adding language-aware rests at punctuation.
    func intervalMilliseconds(
        after character: Character? = nil,
        randomUnit: Double = 0.5
    ) -> Double {
        let base = 60_000 / (wordsPerMinute * 5)
        guard rhythm != .steady else { return base }
        let unit = min(max(randomUnit, 0), 1)
        let centered = (unit - 0.5) * 2
        // Pull most intervals toward the chosen pace instead of producing the
        // mechanical-looking uniform jitter used by the old on/off setting.
        let shaped = centered.sign == .minus
            ? -pow(abs(centered), 1.6)
            : pow(centered, 1.6)
        let randomized = 1 + (shaped * rhythm.jitter)
        return base * rhythm.boundaryMultiplier(after: character) * randomized
    }

    func interval(after character: Character? = nil, randomUnit: Double = 0.5) -> Duration {
        .milliseconds(
            Int64(
                intervalMilliseconds(after: character, randomUnit: randomUnit).rounded()
            )
        )
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
    private enum Unit {
        case text(String)
        case deleteBackward
    }

    private(set) var hadPostingFailure = false
    /// The accessibility check made the instant the queue last drained, before
    /// cleanup runs and before the person can send or edit the text.
    private(set) var deliveryVerification: InsertionVerificationResult?
    private var deliveredText = ""
    private var insertionTask: Task<Void, Never>?
    private var pending: [Unit] = []
    private var nextPendingIndex = 0
    private var expectedTarget: TextInsertionSnapshot?
    private var deliveryMode: TextDeliveryMode = .chunked
    private var drainGeneration = 0

    private enum PasteAcknowledgment {
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
        deliveryVerification = nil
        deliveredText = ""
    }

    /// `deleteBackward` characters are removed before `text` is typed, in the
    /// same serialized queue, so a retracted period can never race its
    /// replacement words.
    func enqueue(_ text: String, deleteBackward: Int = 0) {
        guard !text.isEmpty || deleteBackward > 0 else { return }
        pending.append(contentsOf: Array(repeating: Unit.deleteBackward, count: max(deleteBackward, 0)))
        pending.append(contentsOf: deliveryMode.units(for: text).filter { !$0.isEmpty }.map(Unit.text))
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
        while let unit = dequeue(), !Task.isCancelled {
            let delivered: Bool
            switch (unit, deliveryMode) {
            case (.deleteBackward, _):
                delivered = await deleteBackward()
            case let (.text(text), .chunked):
                delivered = await deliverText(text, minimumInterval: .milliseconds(120))
            case let (.text(text), .characterByCharacter(pacing)):
                delivered = await deliverCharacter(text, pacing: pacing)
            }

            guard delivered else {
                hadPostingFailure = true
                pending.removeAll(keepingCapacity: true)
                nextPendingIndex = 0
                break
            }
            switch unit {
            case let .text(text): deliveredText += text
            case .deleteBackward: deliveredText = String(deliveredText.dropLast())
            }
        }
        if generation == drainGeneration {
            insertionTask = nil
            if !hadPostingFailure, !deliveredText.isEmpty, let expectedTarget {
                deliveryVerification = TextInsertionVerifier.verify(
                    expectedTarget,
                    insertedText: deliveredText,
                    postingFailed: false
                )
            }
        }
    }

    private func dequeue() -> Unit? {
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

    /// Retracts one character Cadence inserted, used when the next words prove
    /// that an automatic period ended the sentence too early. An accessible
    /// editor must show that period directly before the caret; otherwise the
    /// document is left alone and the following words still arrive. Only a
    /// focus change fails the queue, exactly as it does for a paste.
    private func deleteBackward() async -> Bool {
        guard AXIsProcessTrusted(), let expectedTarget,
              TextInsertionVerifier.matchesCurrentTarget(expectedTarget) else { return false }
        if TextInsertionVerifier.insertionPointFollows(".", in: expectedTarget) == false { return true }
        let originalSelection = TextInsertionVerifier.currentSelection(expectedTarget)
        guard let events = Self.deleteBackwardEvents() else { return true }
        for event in events { event.post(tap: .cghidEventTap) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(400))
        guard let originalSelection else {
            await sleep(until: clock.now.advanced(by: .milliseconds(120)), clock: clock)
            return true
        }
        while clock.now < deadline, !Task.isCancelled {
            guard TextInsertionVerifier.matchesCurrentTarget(expectedTarget) else { return false }
            if let current = TextInsertionVerifier.currentSelection(expectedTarget),
               current.location == originalSelection.location - 1,
               current.length == 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(6))
        }
        return true
    }

    private func deliverCharacter(
        _ text: String,
        pacing: CharacterPlaybackPacing
    ) async -> Bool {
        let interval = pacing.interval(
            after: text.first,
            randomUnit: pacing.rhythm == .steady ? 0.5 : .random(in: 0...1)
        )
        return await deliverText(text, minimumInterval: interval)
    }

    /// Every queued paste, including normal chunk delivery, waits for the real
    /// editor cursor when Accessibility exposes it. This prevents a later
    /// pasteboard write from overtaking a slow target and retries a swallowed
    /// Command-V before silently losing text.
    private func deliverText(_ text: String, minimumInterval: Duration) async -> Bool {
        for attempt in 0..<3 {
            let originalSelection = expectedTarget.flatMap(TextInsertionVerifier.currentSelection)
            let startedAt = ContinuousClock.now
            guard paste(text, expectedTarget: expectedTarget) else { return false }

            switch await waitForPaste(
                text,
                originalSelection: originalSelection,
                startedAt: startedAt,
                minimumInterval: minimumInterval
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
    /// point. A missing V event therefore retries the same unit instead of
    /// silently dropping text. Opaque editors retain the conservative timeout.
    private func waitForPaste(
        _ text: String,
        originalSelection: CFRange?,
        startedAt: ContinuousClock.Instant,
        minimumInterval: Duration
    ) async -> PasteAcknowledgment {
        let clock = ContinuousClock()
        let earliestNextPaste = startedAt.advanced(by: minimumInterval)
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
            let opaqueEditorDelay = max(minimumInterval, .milliseconds(120))
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
        keyEvents([
            (0x37, true, .maskCommand),
            (0x09, true, .maskCommand),
            (0x09, false, .maskCommand),
            (0x37, false, [])
        ])
    }

    /// A plain Delete press. Its empty flags matter: the person may still be
    /// holding the ⌃⌥ dictation shortcut, and ⌥Delete would erase a word.
    nonisolated static func deleteBackwardEvents() -> [CGEvent]? {
        keyEvents([(0x33, true, []), (0x33, false, [])])
    }

    private nonisolated static func keyEvents(
        _ steps: [(key: CGKeyCode, isDown: Bool, flags: CGEventFlags)]
    ) -> [CGEvent]? {
        let source = CGEventSource(stateID: .hidSystemState)
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
