import Foundation

/// Applies spoken formatting commands before transcript stabilization. Commands
/// may arrive after the recognizer has already supplied punctuation, so the
/// formatter treats the spoken command as authoritative and coalesces adjacent
/// marks instead of producing output such as `. .` or `,,`.
enum SpokenPunctuationFormatter {
    static func format(_ transcript: String) -> String {
        var result = transcript
        for (pattern, replacement) in punctuationReplacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        for (pattern, replacement) in layoutReplacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        // A punctuation command may follow punctuation inserted by the model.
        // Keep the command's (last) mark and remove only adjacent duplicates.
        for _ in 0..<3 {
            let normalized = result.replacingOccurrences(
                of: #"[.,!?;:][ \t]*(?=[.,!?;:])"#,
                with: "",
                options: .regularExpression
            )
            guard normalized != result else { break }
            result = normalized
        }
        result = result.replacingOccurrences(
            of: #"[ \t]+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[ \t]*\n[ \t]*\n[ \t]*"#,
            with: "\n\n",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
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

        let completions: [String: Set<String>] = [
            "question": ["mark"],
            "exclamation": ["mark", "point"],
            "full": ["stop"],
            "new": ["line", "paragraph"]
        ]
        let isIncompleteCommand = completions[command]?.contains(where: {
            $0.hasPrefix(fragment)
        }) == true
        guard isIncompleteCommand else { return nil }

        var prefixEnd = words[words.count - 2].startIndex
        while prefixEnd > transcript.startIndex {
            let previous = transcript.index(before: prefixEnd)
            guard transcript[previous].isWhitespace else { break }
            prefixEnd = previous
        }
        return prefixEnd
    }

    /// The leading separator is part of the replacement so punctuation never
    /// receives a stray space. Optional punctuation immediately before the
    /// command is model-generated and is replaced by the explicit command.
    private static let punctuationReplacements: [(String, String)] = [
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)question[ \t-]+mark\b[.,!?;:]?"#, "?"),
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)exclamation[ \t-]+(?:mark|point)\b[.,!?;:]?"#, "!"),
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)(?:period|full[ \t-]+stop)\b[.,!?;:]?"#, "."),
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)comma\b[.,!?;:]?"#, ","),
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)semicolon\b[.,!?;:]?"#, ";"),
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)colon\b[.,!?;:]?"#, ":")
    ]

    /// A model often adds a period to “new paragraph” as if it were prose.
    /// Consume punctuation after the command, but preserve punctuation before
    /// it because that belongs to the preceding sentence.
    private static let layoutReplacements: [(String, String)] = [
        (#"(?i)(?:^|[ \t]+)new[ \t-]+paragraph\b[.,!?;:]?[ \t]*"#, "\n\n"),
        (#"(?i)(?:^|[ \t]+)new[ \t-]+line\b[.,!?;:]?[ \t]*"#, "\n")
    ]
}
