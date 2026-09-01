import Foundation

struct SnippetFormattingResult: Equatable, Sendable {
    let text: String
    /// Character offset in `text` before a trailing trigger that must remain
    /// provisional. The offset intentionally excludes the trigger's leading
    /// whitespace so a withdrawn hypothesis cannot leave a stray separator.
    let safePrefixCharacterCount: Int?
    /// True when the formatted hypothesis ends at the replacement for a bare
    /// trigger, with no source punctuation after it. A standalone snippet is
    /// a macro, so finalization must not invent a period inside its saved text.
    let endsWithBareSnippet: Bool
}

/// Replaces exact spoken trigger phrases before any text reaches the target
/// editor. A trailing complete trigger remains provisional until a following
/// word or a real pause confirms it, just like the recognizer's frontier word.
enum SnippetFormatter {
    private struct Candidate {
        let snippet: TextSnippet
        let trigger: String
        let foldedWords: [String]
    }

    private struct Match {
        let candidate: Candidate
        let range: Range<String.Index>
    }

    static func format(_ text: String, snippets: [TextSnippet]) -> SnippetFormattingResult {
        let candidates = effectiveCandidates(from: snippets)
        guard !text.isEmpty, !candidates.isEmpty else {
            return SnippetFormattingResult(
                text: text,
                safePrefixCharacterCount: nil,
                endsWithBareSnippet: false
            )
        }

        let rawCandidateBoundary = trailingIncompleteCandidateStart(in: text, candidates: candidates)
        var mappedCandidateBoundary: Int?
        var trailingReplacementBoundary: Int?
        var endsWithBareSnippet = false
        var output = ""
        var cursor = text.startIndex

        func appendRaw(until upperBound: String.Index) {
            guard cursor <= upperBound else { return }
            if let rawCandidateBoundary,
               mappedCandidateBoundary == nil,
               rawCandidateBoundary >= cursor,
               rawCandidateBoundary <= upperBound {
                output.append(contentsOf: text[cursor..<rawCandidateBoundary])
                mappedCandidateBoundary = output.count
                output.append(contentsOf: text[rawCandidateBoundary..<upperBound])
            } else {
                output.append(contentsOf: text[cursor..<upperBound])
            }
            cursor = upperBound
        }

        while cursor < text.endIndex,
              let match = nextMatch(in: text, from: cursor, candidates: candidates) {
            appendRaw(until: match.range.lowerBound)
            let trailingWhitespaceCount = output.reversed().prefix(while: { $0.isWhitespace }).count
            let boundaryBeforeReplacement = output.count - trailingWhitespaceCount
            output.append(match.candidate.snippet.replacement)
            endsWithBareSnippet = match.range.upperBound == text.endIndex
            if text[match.range.upperBound...].allSatisfy({ !isWordCharacter($0) }) {
                trailingReplacementBoundary = boundaryBeforeReplacement
            }
            cursor = match.range.upperBound
        }
        appendRaw(until: text.endIndex)

        let safeBoundary = [mappedCandidateBoundary, trailingReplacementBoundary]
            .compactMap { $0 }
            .min()
        return SnippetFormattingResult(
            text: output,
            safePrefixCharacterCount: safeBoundary,
            endsWithBareSnippet: endsWithBareSnippet
        )
    }

    private static func effectiveCandidates(from snippets: [TextSnippet]) -> [Candidate] {
        var seen = Set<String>()
        let candidates = snippets.compactMap { snippet -> Candidate? in
            let trigger = TextSnippetValidator.cleanedTrigger(snippet.trigger)
            let words = TextSnippetValidator.foldedWords(in: trigger)
            let key = words.joined(separator: "\u{1F}")
            guard !trigger.isEmpty, !snippet.replacement.isEmpty, seen.insert(key).inserted else { return nil }
            return Candidate(snippet: snippet, trigger: trigger, foldedWords: words)
        }

        // A complete short trigger cannot be safely expanded while it is also
        // the beginning of a longer trigger. The editor prevents this state;
        // corrupted or legacy preferences conservatively keep only the longer
        // trigger so live text can never be revised.
        return candidates
            .filter { candidate in
                !candidates.contains { other in
                    guard other.foldedWords.count > candidate.foldedWords.count else { return false }
                    return zip(candidate.foldedWords, other.foldedWords).allSatisfy(==)
                }
            }
            .sorted { lhs, rhs in lhs.trigger.count > rhs.trigger.count }
    }

    private static func trailingIncompleteCandidateStart(
        in text: String,
        candidates: [Candidate]
    ) -> String.Index? {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }

        var earliest: String.Index?
        for candidate in candidates {
            let maximum = min(words.count, candidate.foldedWords.count)
            guard maximum > 0 else { continue }
            for count in stride(from: maximum, through: 1, by: -1) {
                let suffix = words.suffix(count)
                var matches = true
                for (offset, word) in suffix.enumerated() {
                    let actual = TextSnippetValidator.folded(String(word))
                    let expected = candidate.foldedWords[offset]
                    if offset == count - 1 {
                        let isIncomplete = count < candidate.foldedWords.count || actual != expected
                        if !isIncomplete || !expected.hasPrefix(actual) { matches = false }
                    } else if actual != expected {
                        matches = false
                    }
                }
                guard matches else { continue }

                var boundary = suffix.first?.startIndex ?? text.endIndex
                while boundary > text.startIndex {
                    let previous = text.index(before: boundary)
                    guard text[previous].isWhitespace else { break }
                    boundary = previous
                }
                if earliest.map({ boundary < $0 }) ?? true { earliest = boundary }
                break
            }
        }
        return earliest
    }

    private static func nextMatch(
        in text: String,
        from start: String.Index,
        candidates: [Candidate]
    ) -> Match? {
        var best: Match?
        for candidate in candidates {
            guard let range = firstWholeMatch(of: candidate.trigger, in: text, from: start) else { continue }
            if let current = best {
                if range.lowerBound < current.range.lowerBound
                    || (range.lowerBound == current.range.lowerBound
                        && candidate.trigger.count > current.candidate.trigger.count) {
                    best = Match(candidate: candidate, range: range)
                }
            } else {
                best = Match(candidate: candidate, range: range)
            }
        }
        return best
    }

    private static func firstWholeMatch(
        of trigger: String,
        in text: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var searchStart = start
        while searchStart < text.endIndex,
              let range = text.range(
                  of: trigger,
                  options: [.caseInsensitive, .diacriticInsensitive],
                  range: searchStart..<text.endIndex,
                  locale: Locale(identifier: "en_US_POSIX")
              ) {
            if isWholeWord(range, in: text) { return range }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex,
           isWordCharacter(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if range.upperBound < text.endIndex, isWordCharacter(text[range.upperBound]) {
            return false
        }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || character == "_"
            || character == "'"
            || character == "’"
    }
}
