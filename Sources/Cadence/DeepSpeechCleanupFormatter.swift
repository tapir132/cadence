import Foundation
import NaturalLanguage

/// An opt-in end-of-dictation repair pass. Spoken repairs conventionally have
/// three parts: material the speaker abandons, an optional editing phrase, and
/// the replacement. Cadence looks for lexical overlap across that boundary and
/// removes only the abandoned span. This is deliberately narrower than a prose
/// rewriter and never invents words or consults the surrounding document.
enum DeepSpeechCleanupFormatter {
    private struct WordToken {
        let normalized: String
        let range: Range<String.Index>
    }

    static func format(_ transcript: String, enabled: Bool) -> String {
        guard enabled else { return transcript }

        var result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return transcript }

        result = collapsingRepeatedRepairs(in: result)
        result = collapsingEditingTermRestarts(in: result)
        result = removingStandaloneDiscourseFragments(in: result)
        result = joiningFalseSentenceBoundaries(in: result)
        result = normalizeSpacing(in: result)
        result = capitalizingSentenceStarts(in: result)

        // A dictation made entirely of a discourse marker should not disappear.
        return result.isEmpty ? transcript : result
    }

    /// Finds adjacent repeated word sequences with an optional interregnum:
    /// “there needs to be — like — there needs to be a setting.” Requiring at
    /// least two repeated words preserves emphatic or grammatical single-word
    /// repetition such as “very very” and “had had.”
    private static func collapsingRepeatedRepairs(in text: String) -> String {
        var result = text
        for _ in 0..<8 {
            let tokens = words(in: result)
            guard let removal = repeatedRepairRange(tokens: tokens) else { break }
            result.removeSubrange(removal)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func repeatedRepairRange(tokens: [WordToken]) -> Range<String.Index>? {
        guard tokens.count >= 4 else { return nil }
        var best: (wordCount: Int, range: Range<String.Index>)?

        for secondStart in 2..<tokens.count {
            let maximumGap = min(3, secondStart - 2)
            for gapCount in 0...maximumGap {
                let firstEnd = secondStart - gapCount
                if gapCount > 0 {
                    let gap = tokens[firstEnd..<secondStart].map(\.normalized)
                    guard editingTerms.contains(gap.joined(separator: " ")) else { continue }
                }

                let maximumLength = min(10, firstEnd, tokens.count - secondStart)
                guard maximumLength >= 2 else { continue }
                for length in stride(from: maximumLength, through: 2, by: -1) {
                    let firstStart = firstEnd - length
                    let first = tokens[firstStart..<firstEnd].map(\.normalized)
                    let second = tokens[secondStart..<(secondStart + length)].map(\.normalized)
                    guard first == second else { continue }

                    let range = tokens[firstStart].range.lowerBound..<tokens[secondStart].range.lowerBound
                    if best == nil || length > best?.wordCount ?? 0 {
                        best = (length, range)
                    }
                    break
                }
            }
        }
        return best?.range
    }

    /// Editing terms such as “I mean” are useful only when the replacement
    /// restarts with a two-or-more-word anchor found just before the correction.
    /// “Tuesday, I mean Wednesday” is intentionally left alone because lexical
    /// evidence cannot safely identify how much of the first clause to replace.
    private static func collapsingEditingTermRestarts(in text: String) -> String {
        var result = text
        for _ in 0..<4 {
            let tokens = words(in: result)
            guard let removal = editingTermRestartRange(tokens: tokens) else { break }
            result.removeSubrange(removal)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func editingTermRestartRange(tokens: [WordToken]) -> Range<String.Index>? {
        for cue in restartCues {
            guard tokens.count > cue.count + 3 else { continue }
            for cueStart in 0...(tokens.count - cue.count) {
                let candidate = tokens[cueStart..<(cueStart + cue.count)].map(\.normalized)
                guard candidate == cue else { continue }
                let repairStart = cueStart + cue.count
                guard repairStart + 1 < tokens.count else { continue }

                let maximumOverlap = min(8, repairStart, tokens.count - repairStart)
                for overlap in stride(from: maximumOverlap, through: 2, by: -1) {
                    let repairAnchor = tokens[repairStart..<(repairStart + overlap)]
                        .map(\.normalized)
                    let earliest = max(0, cueStart - 12)
                    guard cueStart >= overlap else { continue }
                    for previousStart in stride(
                        from: cueStart - overlap,
                        through: earliest,
                        by: -1
                    ) {
                        let previousAnchor = tokens[previousStart..<(previousStart + overlap)]
                            .map(\.normalized)
                        guard previousAnchor == repairAnchor else { continue }
                        let lowerBound = tokens[previousStart].range.lowerBound
                        let upperBound = tokens[repairStart].range.lowerBound
                        return lowerBound..<upperBound
                    }
                }
            }
        }
        return nil
    }

    private static func removingStandaloneDiscourseFragments(in text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"(?i)^\s*(?:like|you[ \t]+know|i[ \t]+mean|well)\s*[.!?]\s*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)(?<=[.!?])[ \t]+(?:like|you[ \t]+know|i[ \t]+mean|well)\s*[.!?][ \t]*"#,
            with: " ",
            options: .regularExpression
        )
        return result
    }

    /// The live path refuses to revise a period after it reaches another app.
    /// At completion, when the insertion span can be verified, reuse the same
    /// grammar classifier that protects thinking pauses to join noun fragments,
    /// dependent clauses, and clear modal/WH complements.
    private static func joiningFalseSentenceBoundaries(in text: String) -> String {
        var result = text
        for _ in 0..<8 {
            let ranges = sentenceRanges(in: result)
            guard ranges.count > 1 else { break }
            var joined = false

            for (previousRange, nextRange) in zip(ranges, ranges.dropFirst()) {
                let previousContentRange = trimmedRange(previousRange, in: result)
                let nextContentRange = trimmedRange(nextRange, in: result)
                let between = result[previousContentRange.upperBound..<nextContentRange.lowerBound]
                guard !between.contains("\n\n") else { continue }
                let previous = String(result[previousContentRange])
                let next = String(result[nextContentRange])
                guard shouldJoin(previous: previous, next: next) else { continue }

                let replacement = joinedContinuation(previous: previous, next: next)
                result.replaceSubrange(
                    previousContentRange.lowerBound..<nextContentRange.upperBound,
                    with: replacement
                )
                joined = true
                break
            }
            guard joined else { break }
        }
        return result
    }

    private static func shouldJoin(previous: String, next: String) -> Bool {
        guard previous.last == "." else { return false }
        let previousCore = String(previous.dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previousCore.isEmpty, !next.isEmpty else { return false }

        if PauseBoundaryClassifier.classify(previousCore) == .continuation {
            return true
        }

        let previousWords = normalizedWords(in: previousCore)
        let nextWords = normalizedWords(in: next)
        guard let firstNext = nextWords.first,
              complementStarters.contains(firstNext),
              previousWords.count <= 8,
              previousWords.contains(where: modalVerbs.contains),
              next.last != "?" else { return false }
        return true
    }

    private static func joinedContinuation(previous: String, next: String) -> String {
        let previousCore = String(previous.dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var continuation = next
        if let firstRange = firstWordRange(in: continuation) {
            let word = String(continuation[firstRange])
            let folded = normalized(word)
            if lowercasedContinuationOpeners.contains(folded),
               word.first?.isUppercase == true {
                continuation.replaceSubrange(firstRange, with: word.lowercased())
            }
        }
        return previousCore + " " + continuation
    }

    private static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        return ranges
    }

    private static func trimmedRange(
        _ range: Range<String.Index>,
        in text: String
    ) -> Range<String.Index> {
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound
        while lowerBound < upperBound, text[lowerBound].isWhitespace {
            lowerBound = text.index(after: lowerBound)
        }
        while upperBound > lowerBound {
            let previous = text.index(before: upperBound)
            guard text[previous].isWhitespace else { break }
            upperBound = previous
        }
        return lowerBound..<upperBound
    }

    private static func words(in text: String) -> [WordToken] {
        guard let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{N}]+(?:['’.-][\p{L}\p{N}]+)*"#
        ) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            return WordToken(
                normalized: normalized(String(text[tokenRange])),
                range: tokenRange
            )
        }
    }

    private static func normalizedWords(in text: String) -> [String] {
        words(in: text).map(\.normalized)
    }

    private static func firstWordRange(in text: String) -> Range<String.Index>? {
        words(in: text).first?.range
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func normalizeSpacing(in text: String) -> String {
        var result = text.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[ \t]+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizingSentenceStarts(in text: String) -> String {
        var result = text
        var searchStart = result.startIndex
        while searchStart < result.endIndex {
            guard let first = result[searchStart...].firstIndex(where: { $0.isLetter }) else { break }
            let wordEnd = result[first...].firstIndex(where: {
                !$0.isLetter && $0 != "'" && $0 != "’"
            }) ?? result.endIndex
            let word = String(result[first..<wordEnd])
            if word == word.lowercased(), let character = word.first {
                result.replaceSubrange(first...first, with: String(character).uppercased())
            }

            guard let sentenceEnd = result[wordEnd...].firstIndex(where: {
                $0 == "." || $0 == "!" || $0 == "?" || $0 == "\n"
            }) else { break }
            searchStart = result.index(after: sentenceEnd)
        }
        return result
    }

    private static let editingTerms: Set<String> = [
        "er", "erm", "hmm", "i mean", "like", "uh", "um", "well", "you know"
    ]
    private static let restartCues: [[String]] = [
        ["i", "mean"], ["no", "wait"], ["sorry"]
    ]
    private static let modalVerbs: Set<String> = [
        "can", "could", "may", "might", "must", "should", "will", "would"
    ]
    private static let complementStarters: Set<String> = [
        "how", "that", "what", "when", "where", "whether", "which", "who", "why"
    ]
    private static let lowercasedContinuationOpeners: Set<String> = [
        "and", "are", "but", "he", "how", "is", "it", "or", "she", "so", "that",
        "these", "they", "this", "those", "was", "we", "were", "what", "when",
        "where", "whether", "which", "who", "why", "you"
    ]
}
