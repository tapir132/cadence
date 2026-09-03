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
        let styled = SpokenStyleFormatter.format(dictionaryCorrected)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        let sentenceCased = Self.endsInSentenceMark(completedText)
            ? Self.capitalizingSentenceStart(styled)
            : styled
        return SnippetFormatter.format(sentenceCased, snippets: snippets)
    }

    private func insertionDelta(_ rawDelta: String) -> String {
        guard !rawDelta.isEmpty else { return "" }
        let startsNewSegment = insertedCurrentPrefix.isEmpty && !completedText.isEmpty
        let needsSeparator = startsNewSegment
            && completedText.last?.isWhitespace != true
            && rawDelta.first?.isWhitespace != true
        return (needsSeparator ? " " : "") + rawDelta
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
        // Keep a paragraph command atomic. Once the following word arrives,
        // both newlines become a safe prefix together; a pause/finalization also
        // flushes them immediately.
        if let last = transcript.last, last == "\n" {
            var boundary = transcript.endIndex
            while boundary > transcript.startIndex {
                let previous = transcript.index(before: boundary)
                guard transcript[previous] == "\n" else { break }
                boundary = previous
            }
            return String(transcript[..<boundary])
        }
        guard let boundary = transcript.lastIndex(where: { $0.isWhitespace }) else { return "" }
        return String(transcript[..<boundary])
    }

    static func ensureSentencePunctuation(_ text: String) -> String {
        let trailingBreakCount = text.reversed().prefix(while: { $0 == "\n" }).count
        let trailingBreaks = String(repeating: "\n", count: min(trailingBreakCount, 2))
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return trailingBreaks }

        let closers = CharacterSet(charactersIn: "\"'”’)]}")
        var significant = result.index(before: result.endIndex)
        while significant > result.startIndex,
              result[significant].unicodeScalars.allSatisfy({ closers.contains($0) }) {
            significant = result.index(before: significant)
        }

        let shouldBeQuestion = hasQuestionTag(in: result, through: significant)
        if sentenceMarks.contains(result[significant]) {
            if shouldBeQuestion, result[significant] == "." {
                result.replaceSubrange(significant...significant, with: "?")
            }
            return result + trailingBreaks
        }
        let fallbackMark = shouldBeQuestion ? "?" : "."
        if softPunctuation.contains(result[significant]) {
            result.replaceSubrange(significant...significant, with: fallbackMark)
        } else {
            result.insert(Character(fallbackMark), at: result.index(after: significant))
        }
        return result + trailingBreaks
    }

    /// A comma-delimited conversational tag is strong textual evidence of a
    /// question even when the recognizer falls back to a period. Requiring the
    /// delimiter keeps declarative uses such as “I will let you know” intact.
    private static func hasQuestionTag(in text: String, through terminal: String.Index) -> Bool {
        let candidate = String(text[...terminal])
        return candidate.range(
            of: #"(?i)[,;—–][ \t]*(?:you[ \t]+know|right|correct|okay|ok)[.,!?;:]?$"#,
            options: .regularExpression
        ) != nil
    }

    /// A reset decoder occasionally begins the next segment with lowercase
    /// text. Only normalize an all-lowercase first word after text that already
    /// ends in sentence punctuation; mixed-case dictionary terms such as
    /// `macOS` and exact snippet replacements remain untouched.
    private static func capitalizingSentenceStart(_ text: String) -> String {
        let openers = CharacterSet(charactersIn: "\"'“‘([{")
        guard let first = text.indices.first(where: { index in
            let character = text[index]
            return !character.isWhitespace
                && !character.unicodeScalars.allSatisfy({ openers.contains($0) })
        }), text[first].isLetter else { return text }

        let wordEnd = text[first...].firstIndex(where: { !$0.isLetter && $0 != "'" && $0 != "’" })
            ?? text.endIndex
        let word = String(text[first..<wordEnd])
        guard word == word.lowercased() else { return text }

        var result = text
        result.replaceSubrange(first...first, with: String(text[first]).uppercased())
        return result
    }

    private static func endsInSentenceMark(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let closers = CharacterSet(charactersIn: "\"'”’)]}")
        var significant = text.index(before: text.endIndex)
        while significant > text.startIndex,
              text[significant].isWhitespace
                || text[significant].unicodeScalars.allSatisfy({ closers.contains($0) }) {
            significant = text.index(before: significant)
        }
        return sentenceMarks.contains(text[significant])
    }

    private static func join(_ prefix: String, _ suffix: String) -> String {
        if prefix.isEmpty { return suffix }
        if suffix.isEmpty { return prefix }
        let needsSeparator = prefix.last?.isWhitespace != true && suffix.first?.isWhitespace != true
        return prefix + (needsSeparator ? " " : "") + suffix
    }

    private static let sentenceMarks: Set<Character> = [".", "!", "?"]
    private static let softPunctuation: Set<Character> = [",", ";", ":"]
}
