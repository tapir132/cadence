import Foundation

/// Applies only exact word/phrase matches, ignoring case and diacritics. This
/// lets a saved name such as “José Arcadio Buendía” restore the spelling from
/// an otherwise exact “Jose Arcadio Buendia” decode without fuzzy invention.
enum DictionaryTermFormatter {
    static func apply(to text: String, terms: [String]) -> String {
        var result = text
        for term in terms.sorted(by: { $0.count > $1.count }) where !term.isEmpty {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result.range(
                      of: term,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: searchStart..<result.endIndex,
                      locale: Locale(identifier: "en_US_POSIX")
                  ) {
                guard isWholeWord(range, in: result) else {
                    searchStart = range.upperBound
                    continue
                }

                let lowerOffset = result.distance(from: result.startIndex, to: range.lowerBound)
                result.replaceSubrange(range, with: term)
                searchStart = result.index(
                    result.startIndex,
                    offsetBy: lowerOffset + term.count,
                    limitedBy: result.endIndex
                ) ?? result.endIndex
            }
        }
        return result
    }

    /// If the live transcript ends with the beginning of a saved multiword
    /// phrase, keep that phrase provisional until it either completes or stops
    /// matching. Otherwise its first word could be pasted before Cadence knows
    /// to restore the phrase's exact spelling.
    static func safePrefixEndBeforeTrailingCandidate(
        in transcript: String,
        terms: [String]
    ) -> String.Index? {
        let words = transcript.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }

        var earliest: String.Index?
        for term in terms {
            let termWords = term.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard termWords.count > 1 else { continue }

            let maximum = min(words.count, termWords.count - 1)
            for count in stride(from: maximum, through: 1, by: -1) {
                let candidateWords = words.suffix(count)
                let allMatch = zip(candidateWords, termWords.prefix(count)).enumerated().allSatisfy {
                    offset, pair in
                    let candidate = folded(String(pair.0))
                    let expected = folded(pair.1)
                    return offset == count - 1
                        ? expected.hasPrefix(candidate)
                        : candidate == expected
                }
                guard allMatch else { continue }

                var boundary = candidateWords.first?.startIndex ?? transcript.endIndex
                while boundary > transcript.startIndex {
                    let previous = transcript.index(before: boundary)
                    guard transcript[previous].isWhitespace else { break }
                    boundary = previous
                }
                if let currentEarliest = earliest {
                    if boundary < currentEarliest { earliest = boundary }
                } else {
                    earliest = boundary
                }
                break
            }
        }
        return earliest
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
        character.isLetter || character.isNumber || character == "_"
    }

    private static func folded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
