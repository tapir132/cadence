import Foundation

struct LiveTranscriptUpdate: Sendable, Equatable {
    /// Everything recognized so far, including the unfinished word shown in
    /// the floating preview.
    let transcript: String

    /// The append-only suffix that is now safe to insert into the editor.
    /// Cadence deliberately holds the frontier word until a following word or
    /// sentence boundary proves that the model has finished spelling it.
    let insertion: String

    let sentenceFinal: Bool
}

enum LiveTranscriptError: LocalizedError, Equatable {
    case revisedVisibleText(previous: String, replacement: String)

    var errorDescription: String? {
        switch self {
        case .revisedVisibleText:
            "The speech model tried to change words already inserted. Cadence stopped before overwriting your document."
        }
    }
}

/// Converts the Unified model's cumulative transcript into word-sized,
/// append-only insertion deltas. Streaming hypotheses may revise their newest
/// token, so the last whitespace-delimited word remains preview-only until its
/// following boundary arrives or the segment is finalized.
struct LiveTranscriptEmitter {
    private struct PendingPrefix {
        let text: String
        let firstSeenAt: ContinuousClock.Instant
    }

    private(set) var completedText = ""
    private(set) var currentPartial = ""
    private(set) var insertedCurrentPrefix = ""
    private var pendingPrefixes: [PendingPrefix] = []
    let cleanupEnabled: Bool
    let dictionaryTerms: [String]
    let snippets: [TextSnippet]
    let insertionDelay: Duration

    init(
        cleanupEnabled: Bool = false,
        dictionaryTerms: [String] = [],
        snippets: [TextSnippet] = [],
        insertionDelay: Duration = .zero
    ) {
        self.cleanupEnabled = cleanupEnabled
        self.dictionaryTerms = dictionaryTerms
        self.snippets = snippets
        self.insertionDelay = insertionDelay
    }

    var transcript: String {
        Self.join(completedText, currentPartial)
    }

    var hasOpenSegment: Bool { !currentPartial.isEmpty || !insertedCurrentPrefix.isEmpty }

    mutating func consume(
        _ rawPartial: String,
        at now: ContinuousClock.Instant = .now
    ) throws -> LiveTranscriptUpdate? {
        let formatted = format(rawPartial)
        let partial = formatted.text
        let partialChanged = partial != currentPartial
        guard partial.hasPrefix(insertedCurrentPrefix) else {
            throw LiveTranscriptError.revisedVisibleText(
                previous: insertedCurrentPrefix,
                replacement: partial
            )
        }

        currentPartial = partial
        let safePrefix = safePrefix(
            in: partial,
            snippetBoundaryCount: formatted.safePrefixCharacterCount
        )
        // The model may temporarily withdraw the uncommitted frontier. In that
        // case `safePrefix` can be shorter than the text already inserted even
        // though `partial` still preserves every visible character. Update the
        // preview and wait for a later hypothesis instead of aborting.
        guard safePrefix.hasPrefix(insertedCurrentPrefix) else {
            return partialChanged
                ? LiveTranscriptUpdate(transcript: transcript, insertion: "", sentenceFinal: false)
                : nil
        }

        let committablePrefix = delayedPrefix(from: safePrefix, at: now)
        let rawDelta = String(committablePrefix.dropFirst(insertedCurrentPrefix.count))
        let insertion = insertionDelta(rawDelta)
        insertedCurrentPrefix = committablePrefix
        guard partialChanged || !insertion.isEmpty else { return nil }
        return LiveTranscriptUpdate(
            transcript: transcript,
            insertion: insertion,
            sentenceFinal: false
        )
    }

    /// Commits the held frontier at a detected pause without closing the ASR
    /// stream. If speech resumes, the recognizer retains the words before the
    /// pause as language context and can decide whether punctuation belongs
    /// there. No visible text is revised.
    mutating func flushPauseTail(_ rawPartial: String) throws -> LiveTranscriptUpdate? {
        let partial = format(rawPartial).text
        guard !partial.isEmpty else { return nil }
        guard partial.hasPrefix(insertedCurrentPrefix) else {
            throw LiveTranscriptError.revisedVisibleText(
                previous: insertedCurrentPrefix,
                replacement: partial
            )
        }

        let rawDelta = String(partial.dropFirst(insertedCurrentPrefix.count))
        let insertion = insertionDelta(rawDelta)
        let changed = partial != currentPartial || !insertion.isEmpty
        currentPartial = partial
        insertedCurrentPrefix = partial
        pendingPrefixes.removeAll(keepingCapacity: true)
        guard changed else { return nil }

        return LiveTranscriptUpdate(
            transcript: transcript,
            insertion: insertion,
            sentenceFinal: false
        )
    }

    func pauseBoundaryDecision(for rawPartial: String) -> PauseBoundaryDecision {
        PauseBoundaryClassifier.classify(format(rawPartial).text)
    }

    /// Flushes the frontier word at a real sentence boundary. Parakeet normally
    /// supplies punctuation in its final right-context window; the fallback
    /// guarantees normal dictation punctuation when the shortcut is released
    /// too soon for the acoustic model to emit it.
    mutating func finalize(
        _ rawFinal: String,
        continuesAfterPause: Bool
    ) throws -> LiveTranscriptUpdate? {
        let formatted = format(rawFinal)
        let unpunctuated = formatted.text
        guard !unpunctuated.isEmpty else {
            currentPartial = ""
            insertedCurrentPrefix = ""
            return nil
        }
        guard unpunctuated.hasPrefix(insertedCurrentPrefix) else {
            throw LiveTranscriptError.revisedVisibleText(
                previous: insertedCurrentPrefix,
                replacement: unpunctuated
            )
        }

        let final = formatted.endsWithBareSnippet
            ? unpunctuated
            : Self.ensureSentencePunctuation(unpunctuated)
        guard final.hasPrefix(insertedCurrentPrefix) else {
            throw LiveTranscriptError.revisedVisibleText(
                previous: insertedCurrentPrefix,
                replacement: final
            )
        }

        let rawDelta = String(final.dropFirst(insertedCurrentPrefix.count))
        let insertion = insertionDelta(rawDelta)
        completedText = Self.join(completedText, final)
        currentPartial = ""
        insertedCurrentPrefix = ""
        pendingPrefixes.removeAll(keepingCapacity: true)

        return LiveTranscriptUpdate(
            transcript: completedText,
            insertion: insertion,
            sentenceFinal: continuesAfterPause
        )
    }

    mutating func reset() {
        completedText = ""
        currentPartial = ""
        insertedCurrentPrefix = ""
        pendingPrefixes.removeAll(keepingCapacity: true)
    }

    private func format(_ transcript: String) -> SnippetFormattingResult {
        let cleaned = SpeechCleanupFormatter.format(transcript, enabled: cleanupEnabled)
        let punctuated = SpokenPunctuationFormatter.format(cleaned)
        let dictionaryCorrected = DictionaryTermFormatter.apply(to: punctuated, terms: dictionaryTerms)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SnippetFormatter.format(dictionaryCorrected, snippets: snippets)
    }

    private func insertionDelta(_ rawDelta: String) -> String {
        guard !rawDelta.isEmpty else { return "" }
        let startsNewSegment = insertedCurrentPrefix.isEmpty && !completedText.isEmpty
        return (startsNewSegment ? " " : "") + rawDelta
    }

    /// When the optional buffer is enabled, a safe prefix must remain present
    /// for the configured duration before it becomes immutable editor text.
    /// Prefix checkpoints preserve each word's own first-seen time, while any
    /// checkpoint contradicted by a newer unpasted hypothesis is discarded.
    private mutating func delayedPrefix(
        from safePrefix: String,
        at now: ContinuousClock.Instant
    ) -> String {
        guard insertionDelay > .zero else {
            pendingPrefixes.removeAll(keepingCapacity: true)
            return safePrefix
        }

        pendingPrefixes.removeAll { checkpoint in
            !safePrefix.hasPrefix(checkpoint.text)
                || !checkpoint.text.hasPrefix(insertedCurrentPrefix)
        }
        if safePrefix.count > insertedCurrentPrefix.count,
           !pendingPrefixes.contains(where: { $0.text == safePrefix }) {
            pendingPrefixes.append(PendingPrefix(text: safePrefix, firstSeenAt: now))
        }

        let eligible = pendingPrefixes
            .filter { checkpoint in
                checkpoint.firstSeenAt.duration(to: now) >= insertionDelay
            }
            .max { lhs, rhs in lhs.text.count < rhs.text.count }
        guard let eligible else { return insertedCurrentPrefix }

        pendingPrefixes.removeAll { $0.text.count <= eligible.text.count }
        return eligible.text
    }

    /// Everything before the frontier word is safe to insert. Exclude the
    /// boundary whitespace as well: the next committed word supplies its own
    /// leading separator, so a withdrawn frontier can still be replaced with
    /// sentence punctuation without leaving `word .` in the editor.
    private func safePrefix(in transcript: String, snippetBoundaryCount: Int?) -> String {
        let commandBoundary = SpokenPunctuationFormatter.safePrefixEndBeforeTrailingCommand(in: transcript)
        let dictionaryBoundary = DictionaryTermFormatter.safePrefixEndBeforeTrailingCandidate(
            in: transcript,
            terms: dictionaryTerms
        )
        let snippetBoundary = snippetBoundaryCount.flatMap { count in
            transcript.index(transcript.startIndex, offsetBy: count, limitedBy: transcript.endIndex)
        }
        if let boundary = [commandBoundary, dictionaryBoundary, snippetBoundary].compactMap({ $0 }).min() {
            return String(transcript[..<boundary])
        }
        guard let boundary = transcript.lastIndex(where: { $0.isWhitespace }) else { return "" }
        return String(transcript[..<boundary])
    }

    static func ensureSentencePunctuation(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        let closers = CharacterSet(charactersIn: "\"'”’)]}")
        var significant = result.index(before: result.endIndex)
        while significant > result.startIndex,
              result[significant].unicodeScalars.allSatisfy({ closers.contains($0) }) {
            significant = result.index(before: significant)
        }

        if sentenceMarks.contains(result[significant]) { return result }
        if softPunctuation.contains(result[significant]) {
            result.replaceSubrange(significant...significant, with: ".")
        } else {
            result.insert(".", at: result.index(after: significant))
        }
        return result
    }

    private static func join(_ prefix: String, _ suffix: String) -> String {
        if prefix.isEmpty { return suffix }
        if suffix.isEmpty { return prefix }
        return prefix + " " + suffix
    }

    private static let sentenceMarks: Set<Character> = [".", "!", "?"]
    private static let softPunctuation: Set<Character> = [",", ";", ":"]
}
