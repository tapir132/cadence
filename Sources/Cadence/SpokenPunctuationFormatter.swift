import Foundation

/// Applies the small set of spoken punctuation commands Cadence guarantees.
/// Formatting happens before transcript stabilization so commands can revise
/// safely in the preview and become normal append-only insertion text.
enum SpokenPunctuationFormatter {
    static func format(_ transcript: String) -> String {
        var result = transcript
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }

    /// A multiword command arrives a token at a time. While the decoder has
    /// only produced `question ma…` or `full st…`, keep both words provisional
    /// so the first word is not inserted immediately before the completed
    /// command turns the pair into punctuation.
    static func safePrefixEndBeforeTrailingCommand(in transcript: String) -> String.Index? {
        let words = transcript.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 2 else { return nil }

        let command = words[words.count - 2].lowercased()
        let fragment = words[words.count - 1]
            .lowercased()
            .filter(\.isLetter)
        guard !fragment.isEmpty else { return nil }

        let isIncompleteCommand =
            (command == "question" && "mark".hasPrefix(fragment)) ||
            (command == "full" && "stop".hasPrefix(fragment))
        guard isIncompleteCommand else { return nil }

        var prefixEnd = words[words.count - 2].startIndex
        while prefixEnd > transcript.startIndex {
            let previous = transcript.index(before: prefixEnd)
            guard transcript[previous].isWhitespace else { break }
            prefixEnd = previous
        }
        return prefixEnd
    }

    private static let replacements: [(String, String)] = [
        (#"(?i)(^|[ \t]+)question[ \t-]+mark\b[.,!?;:]?"#, "?"),
        (#"(?i)(^|[ \t]+)(?:period|full[ \t]+stop)\b[.,!?;:]?"#, ".")
    ]
}
