import Foundation

/// Conservative cleanup that is safe before any text becomes visible. Cadence
/// intentionally limits this to unmistakable hesitation sounds: broader
/// rewriting would need to edit words that may already exist in another app.
enum SpeechCleanupFormatter {
    static func format(_ transcript: String, enabled: Bool) -> String {
        guard enabled else { return transcript }

        var result = transcript
        let fillerPattern = #"(?i)(^|[ \t]+)(?:u+h+|u+m+|e+r+m+|e+r+)(?:[ \t]*[,;:.!?])?(?:[ \t]+|$)"#
        let removedLeadingFiller = transcript.range(
            of: #"(?i)^[ \t]*(?:u+h+|u+m+|e+r+m+|e+r+)(?:[ \t]*[,;:.!?])?(?:[ \t]+|$)"#,
            options: .regularExpression
        ) != nil

        // A match consumes its trailing separator. Iterate so adjacent fillers
        // such as "um uh" are both removed while retaining one word boundary.
        for _ in 0..<4 {
            let cleaned = result.replacingOccurrences(
                of: fillerPattern,
                with: "$1",
                options: .regularExpression
            )
            guard cleaned != result else { break }
            result = cleaned
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return removedLeadingFiller ? capitalizingPlainLeadingWord(in: result) : result
    }

    private static func capitalizingPlainLeadingWord(in text: String) -> String {
        guard let first = text.firstIndex(where: { $0.isLetter }) else { return text }
        let end = text[first...].firstIndex(where: { !$0.isLetter && $0 != "'" && $0 != "’" })
            ?? text.endIndex
        let word = String(text[first..<end])
        // Preserve intentional mixed-case names such as iPhone or macOS.
        guard word == word.lowercased(), let firstCharacter = word.first else { return text }

        var result = text
        result.replaceSubrange(first...first, with: String(firstCharacter).uppercased())
        return result
    }
}
