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
    private(set) var completedText = ""
    private(set) var currentPartial = ""
    private(set) var insertedCurrentPrefix = ""

    var transcript: String {
        Self.join(completedText, currentPartial)
    }

    mutating func consume(_ rawPartial: String) throws -> LiveTranscriptUpdate? {
        let partial = SpokenPunctuationFormatter.format(rawPartial)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard partial != currentPartial else { return nil }
        guard partial.hasPrefix(insertedCurrentPrefix) else {
            throw LiveTranscriptError.revisedVisibleText(
                previous: insertedCurrentPrefix,
                replacement: partial
            )
        }

        currentPartial = partial
        let safePrefix = Self.safePrefix(in: partial)
        // The model may temporarily withdraw the uncommitted frontier. In that
        // case `safePrefix` can be shorter than the text already inserted even
        // though `partial` still preserves every visible character. Update the
        // preview and wait for a later hypothesis instead of aborting.
        guard safePrefix.hasPrefix(insertedCurrentPrefix) else {
            return LiveTranscriptUpdate(
                transcript: transcript,
                insertion: "",
                sentenceFinal: false
            )
        }

        let rawDelta = String(safePrefix.dropFirst(insertedCurrentPrefix.count))
        let insertion = insertionDelta(rawDelta)
        insertedCurrentPrefix = safePrefix
        return LiveTranscriptUpdate(
            transcript: transcript,
            insertion: insertion,
            sentenceFinal: false
        )
    }

    /// Flushes the frontier word at a real sentence boundary. Parakeet normally
    /// supplies punctuation in its final right-context window; the fallback
    /// guarantees normal dictation punctuation when the shortcut is released
    /// too soon for the acoustic model to emit it.
    mutating func finalize(
        _ rawFinal: String,
        continuesAfterPause: Bool
    ) throws -> LiveTranscriptUpdate? {
        let unpunctuated = SpokenPunctuationFormatter.format(rawFinal)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

        let final = Self.ensureSentencePunctuation(unpunctuated)
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
    }

    private func insertionDelta(_ rawDelta: String) -> String {
        guard !rawDelta.isEmpty else { return "" }
        let startsNewSegment = insertedCurrentPrefix.isEmpty && !completedText.isEmpty
        return (startsNewSegment ? " " : "") + rawDelta
    }

    /// Everything before the frontier word is safe to insert. Exclude the
    /// boundary whitespace as well: the next committed word supplies its own
    /// leading separator, so a withdrawn frontier can still be replaced with
    /// sentence punctuation without leaving `word .` in the editor.
    static func safePrefix(in transcript: String) -> String {
        if let commandBoundary = SpokenPunctuationFormatter.safePrefixEndBeforeTrailingCommand(
            in: transcript
        ) {
            return String(transcript[..<commandBoundary])
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
