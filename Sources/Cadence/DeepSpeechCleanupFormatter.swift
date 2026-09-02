import Foundation

/// An opt-in end-of-dictation pass for revisions that cannot be made safely on
/// the append-only live frontier. It is intentionally narrow: exact repeated
/// phrases, standalone discourse fillers, and a short list of obvious split
/// complements. It never guesses at a different word or reads document context.
enum DeepSpeechCleanupFormatter {
    static func format(_ transcript: String, enabled: Bool) -> String {
        guard enabled else { return transcript }

        var result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return transcript }

        // Collapse adjacent repetitions of two or more words. Keeping the later
        // punctuation means "You can toggle. You can toggle." retains one full
        // sentence, while an in-sentence restart keeps its following clause.
        let repeatedPhrase = #"(?i)\b((?:[\p{L}\p{N}]+(?:['’.-][\p{L}\p{N}]+)*[ \t]+){1,9}[\p{L}\p{N}]+(?:['’.-][\p{L}\p{N}]+)*)[ \t]*[,;:.!?]?[ \t]+\1\b"#
        for _ in 0..<6 {
            let collapsed = result.replacingOccurrences(
                of: repeatedPhrase,
                with: "$1",
                options: .regularExpression
            )
            guard collapsed != result else { break }
            result = collapsed
        }

        result = result.replacingOccurrences(
            of: #"(?i)^\s*(?:like|you[ \t]+know)\s*[.!?]\s*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)(?<=[.!?])[ \t]+(?:like|you[ \t]+know)\s*[.!?][ \t]*"#,
            with: " ",
            options: .regularExpression
        )

        result = joiningClearComplementFragments(in: result)
        result = result.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"[ \t]+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // A dictation made entirely of a discourse filler should not disappear.
        return result.isEmpty ? transcript : result
    }

    private static func joiningClearComplementFragments(in text: String) -> String {
        let pattern = #"(?i)\b((?:can|could|will|would|should|to)[ \t]+(?:toggle|set|choose|control|adjust|change|decide|select|specify|see))[ \t]*[.!?][ \t]+(how|what|where|when|whether|which|who|why|that)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }

        let result = NSMutableString(string: text)
        let fullRange = NSRange(location: 0, length: result.length)
        for match in expression.matches(in: text, range: fullRange).reversed() {
            guard match.numberOfRanges == 3 else { continue }
            let bridge = result.substring(with: match.range(at: 1))
            let complement = result.substring(with: match.range(at: 2)).lowercased()
            result.replaceCharacters(in: match.range, with: "\(bridge) \(complement)")
        }
        return result as String
    }
}
