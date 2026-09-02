import Foundation

/// Normalizes a deliberately small set of spoken forms that have an
/// unambiguous written form in ordinary correspondence. This is separate from
/// the personal dictionary: it never guesses the spelling of a person's name.
enum SpokenStyleFormatter {
    static func format(_ transcript: String) -> String {
        transcript.replacingOccurrences(
            of: #"\b[Dd]octor[ \t]+(?=\p{Lu})"#,
            with: "Dr. ",
            options: .regularExpression
        )
    }
}
