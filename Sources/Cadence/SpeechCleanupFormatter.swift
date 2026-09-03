import Foundation

/// Conservative cleanup that is safe before any text becomes visible. It uses
/// two different signals: unmistakable vocalized pauses can be removed on their
/// own, while real words such as “like” and “well” are removed only when
/// punctuation marks them as a detached discourse aside. Semantic uses such as
/// “I like this” and “it is well designed” remain untouched.
enum SpeechCleanupFormatter {
    static func format(
        _ transcript: String,
        enabled: Bool,
        capitalizeLeadingWord: Bool = true
    ) -> String {
        guard enabled else { return transcript }

        var result = transcript
        let removedLeadingPause = transcript.range(
            of: #"(?i)^[ \t]*(?:u+h+m*|u+m+|e+r+m+|e+r+|h+m+)(?:[ \t]*[,;:.!?])?(?:[ \t]+|$)"#,
            options: .regularExpression
        ) != nil
        let removedLeadingDiscourseMarker = transcript.range(
            of: #"(?i)^[ \t]*(?:like|well|you[ \t]+know|i[ \t]+mean)[ \t]*[,;:—-][ \t]*"#,
            options: .regularExpression
        ) != nil

        // Remove the punctuation pair along with a parenthetical filler. This
        // turns “I, um, think” into “I think,” not the malformed “I, think.”
        for pattern in [detachedPausePattern, detachedDiscoursePattern] {
            for _ in 0..<4 {
                let cleaned = result.replacingOccurrences(
                    of: pattern,
                    with: " ",
                    options: .regularExpression
                )
                guard cleaned != result else { break }
                result = cleaned
            }
        }

        result = result.replacingOccurrences(
            of: leadingDiscoursePattern,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: sentenceInitialDiscoursePattern,
            with: "$1",
            options: .regularExpression
        )

        // A match consumes its trailing separator. Iterate so adjacent fillers
        // such as "um uh" are both removed while retaining one word boundary.
        for _ in 0..<4 {
            let cleaned = result.replacingOccurrences(
                of: vocalizedPausePattern,
                with: "$1",
                options: .regularExpression
            )
            guard cleaned != result else { break }
            result = cleaned
        }
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
        return capitalizeLeadingWord && (removedLeadingPause || removedLeadingDiscourseMarker)
            ? capitalizingPlainLeadingWord(in: result)
            : result
    }

    private static let pause = #"(?:u+h+m*|u+m+|e+r+m+|e+r+|h+m+)"#
    private static let vocalizedPausePattern =
        #"(?i)(^|[ \t]+)"# + pause + #"(?:[ \t]*[,;:.!?])?(?:[ \t]+|$)"#
    private static let detachedPausePattern =
        #"(?i)[ \t]*[,;:—-][ \t]*"# + pause + #"[ \t]*[,;:—-][ \t]*"#
    private static let detachedDiscoursePattern =
        #"(?i)[ \t]*[,;:—-][ \t]*(?:like|well|you[ \t]+know)[ \t]*[,;:—-][ \t]*"#
    private static let leadingDiscoursePattern =
        #"(?i)^[ \t]*(?:like|well|you[ \t]+know|i[ \t]+mean)[ \t]*[,;:—-][ \t]*"#
    private static let sentenceInitialDiscoursePattern =
        #"(?i)([.!?])[ \t]+(?:like|well|you[ \t]+know)[ \t]*[,;:—-][ \t]*"#

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
