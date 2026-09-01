import Foundation

enum PauseBoundaryDecision: Equatable {
    /// Punctuation from the live model is strong enough to close immediately.
    case complete
    /// The fragment grammatically promises more, so preserve ASR context even
    /// through a long pause.
    case continuation
    /// Wait briefly for more speech before treating the pause as a sentence.
    case uncertain
}

/// A deliberately conservative, local sentence-boundary check. It combines
/// punctuation already emitted by the recognizer with grammar signals that are
/// difficult to interpret as a complete thought. Uncertain fragments receive a
/// temporal grace period in `LiveSpeechTranscriber` rather than a guessed stop.
enum PauseBoundaryClassifier {
    static func classify(_ transcript: String) -> PauseBoundaryDecision {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .uncertain }

        if let terminal = significantTerminal(in: text) {
            if sentenceMarks.contains(terminal) { return .complete }
            if continuationMarks.contains(terminal) { return .continuation }
        }

        if hasUnclosedGrouping(in: text) { return .continuation }

        let normalized = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        let words = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return .uncertain }

        if trailingContinuationWords.contains(words.last ?? "") { return .continuation }
        if trailingContinuationPhrases.contains(where: { words.suffix($0.count) == $0[...] }) {
            return .continuation
        }

        // A leading dependent clause normally needs a comma and an independent
        // clause before it can stand alone. This directly covers pauses such as
        // "Because my Apple dictation …" without delaying every sentence.
        if leadingDependentPhrases.contains(where: { words.starts(with: $0) }),
           !text.contains(where: clauseSeparators.contains) {
            return .continuation
        }

        return .uncertain
    }

    private static func significantTerminal(in text: String) -> Character? {
        let closers = CharacterSet(charactersIn: "\"'”’)]}")
        var index = text.index(before: text.endIndex)
        while index > text.startIndex,
              text[index].unicodeScalars.allSatisfy({ closers.contains($0) }) {
            index = text.index(before: index)
        }
        return text[index]
    }

    private static func hasUnclosedGrouping(in text: String) -> Bool {
        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("{", "}")]
        return pairs.contains { opening, closing in
            text.filter { $0 == opening }.count > text.filter { $0 == closing }.count
        }
    }

    private static let sentenceMarks: Set<Character> = [".", "!", "?"]
    private static let continuationMarks: Set<Character> = [",", ";", ":", "—", "–"]
    private static let clauseSeparators: Set<Character> = [",", ";", ":", "—", "–"]

    private static let trailingContinuationWords: Set<String> = [
        "a", "although", "an", "and", "because", "but", "either", "if", "my",
        "nor", "or", "our", "the", "their", "unless", "whereas", "your"
    ]

    private static let trailingContinuationPhrases: [[String]] = [
        ["as", "well", "as"],
        ["even", "if"],
        ["even", "though"],
        ["in", "order", "to"],
        ["rather", "than"],
        ["so", "that"],
        ["such", "as"]
    ]

    private static let leadingDependentPhrases: [[String]] = [
        ["after"], ["although"], ["as", "long", "as"], ["as", "soon", "as"],
        ["because"], ["before"], ["even", "if"], ["even", "though"],
        ["especially", "when"], ["if"], ["once"], ["though"], ["unless"],
        ["until"], ["when"], ["whenever"], ["whereas"], ["while"]
    ]
}
