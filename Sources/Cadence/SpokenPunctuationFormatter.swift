import Foundation

/// Applies spoken formatting commands before transcript stabilization. Commands
/// may arrive after the recognizer has already supplied punctuation, so the
/// formatter treats the spoken command as authoritative and coalesces adjacent
/// marks instead of producing output such as `. .` or `,,`.
enum SpokenPunctuationFormatter {
    static func format(_ transcript: String) -> String {
        var result = replacingPunctuationCommands(in: transcript)
        result = replacingLayoutCommands(in: result)

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

        let commandStart = words[words.count - 2].startIndex
        if isLiteralCommandPhrase(
            in: transcript,
            phraseRange: commandStart..<transcript.endIndex
        ) {
            return nil
        }

        var prefixEnd = commandStart
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
    private static let punctuationReplacements: [(pattern: String, replacement: String)] = [
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)(question[ \t-]+mark)\b[.,!?;:]?"#, "?"),
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)(exclamation[ \t-]+(?:mark|point))\b[.,!?;:]?"#, "!"),
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)((?:period|full[ \t-]+stop))\b[.,!?;:]?"#, "."),
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)(comma)\b[.,!?;:]?"#, ","),
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)(semicolon)\b[.,!?;:]?"#, ";"),
        (#"(?i)(?:^|(?:[ \t]*[.,!?;:])?[ \t]+)(colon)\b[.,!?;:]?"#, ":")
    ]

    private static func replacingPunctuationCommands(in text: String) -> String {
        var result = text
        for command in punctuationReplacements {
            guard let expression = try? NSRegularExpression(pattern: command.pattern) else {
                continue
            }
            let searchRange = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = expression.matches(in: result, range: searchRange)
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: result),
                      let phraseRange = Range(match.range(at: 1), in: result),
                      !isLiteralCommandPhrase(in: result, phraseRange: phraseRange)
                else { continue }
                result.replaceSubrange(matchRange, with: command.replacement)
            }
        }
        return result
    }

    /// A model often adds a period to “new paragraph” as if it were prose.
    /// Consume punctuation after the command, but preserve punctuation before
    /// it because that belongs to the preceding sentence.
    private static let layoutReplacements: [(pattern: String, replacement: String)] = [
        (#"(?i)(?:^|[ \t]+)(new[ \t-]+paragraph)\b[.,!?;:]?[ \t]*"#, "\n\n"),
        (#"(?i)(?:^|[ \t]+)(new[ \t-]+line)\b[.,!?;:]?[ \t]*"#, "\n")
    ]

    private static func replacingLayoutCommands(in text: String) -> String {
        var result = text
        for command in layoutReplacements {
            guard let expression = try? NSRegularExpression(pattern: command.pattern) else {
                continue
            }
            let searchRange = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = expression.matches(in: result, range: searchRange)
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: result),
                      let phraseRange = Range(match.range(at: 1), in: result),
                      !isLiteralCommandPhrase(in: result, phraseRange: phraseRange)
                else { continue }
                result.replaceSubrange(matchRange, with: command.replacement)
            }
        }
        return result
    }

    /// Spoken formatting has no separate command channel, so grammar must
    /// disambiguate a requested break from literal language. Determiners and
    /// metalinguistic words make “new line” or “new paragraph” part of the
    /// sentence, as in “goes into a new line” or “the words new paragraph.”
    private static func isLiteralCommandPhrase(
        in text: String,
        phraseRange: Range<String.Index>
    ) -> Bool {
        let previous = word(before: phraseRange.lowerBound, in: text)
        let following = word(after: phraseRange.upperBound, in: text)
        return previous.map(literalCommandPredecessors.contains) == true
            || following.map(literalCommandFollowers.contains) == true
    }

    private static func word(before index: String.Index, in text: String) -> String? {
        var end = index
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard !text[previous].isLetter else { break }
            end = previous
        }
        var start = end
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard text[previous].isLetter else { break }
            start = previous
        }
        guard start < end else { return nil }
        return text[start..<end].lowercased()
    }

    private static func word(after index: String.Index, in text: String) -> String? {
        var start = index
        while start < text.endIndex, !text[start].isLetter {
            start = text.index(after: start)
        }
        var end = start
        while end < text.endIndex, text[end].isLetter {
            end = text.index(after: end)
        }
        guard start < end else { return nil }
        return text[start..<end].lowercased()
    }

    private static let literalCommandPredecessors: Set<String> = [
        "a", "an", "another", "called", "each", "every", "interpret",
        "interpreting", "interprets", "literal", "phrase", "say", "saying",
        "says", "spell", "spelled", "term", "the", "type", "typed", "typing",
        "word", "words", "write", "writes", "writing", "wrote", "named",
        "punctuation", "symbol", "symbols", "than"
    ]
    private static let literalCommandFollowers: Set<String> = [
        "are", "as", "character", "command", "into", "is", "means", "meaning",
        "punctuation", "symbol", "symbols", "with", "word", "words"
    ]
}
