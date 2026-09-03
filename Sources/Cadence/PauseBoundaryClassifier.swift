import Foundation
import NaturalLanguage

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

        // Thinking pauses in this corpus land after a preposition or degree
        // word (“things like”, “a lot of”, “it's really”), and after a copula
        // or modal whose subject is a noun phrase (“the whole point is”).
        // “I like that” and “yes it is” stay uncertain because a pronoun
        // subject makes those endings complete.
        if let last = words.last, words.count > 1 {
            let previous = words[words.count - 2]
            if trailingPrepositions.contains(last) { return .continuation }
            if last == "like", !pronounSubjects.contains(previous) { return .continuation }
            if trailingAuxiliaries.contains(last), !pronounSubjects.contains(previous) {
                return .continuation
            }
        }

        // A trailing "that" after a linking or reporting verb introduces a
        // complement; it is not the end of the thought. Keep cases such as
        // "I like that" uncertain rather than treating every final "that" as
        // incomplete.
        if words.last == "that",
           words.dropLast().contains(where: complementIntroducingVerbs.contains) {
            return .continuation
        }

        // A leading dependent clause normally needs a comma and an independent
        // clause before it can stand alone. This directly covers pauses such as
        // "Because my Apple dictation …" without delaying every sentence.
        if leadingDependentPhrases.contains(where: { words.starts(with: $0) }),
           !text.contains(where: clauseSeparators.contains) {
            return .continuation
        }

        // Long thinking pauses often land between a subject and its predicate:
        // "The whole point of the app … is that …". Apple's local lexical
        // tagger gives us a conservative way to recognize a multiword phrase
        // with no verb and preserve decoder context until speech resumes.
        if words.count > 1, !containsVerb(in: text) { return .continuation }

        return .uncertain
    }

    private static func containsVerb(in text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var found = false
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, _ in
            found = tag == .verb
            return !found
        }
        return found
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

    private static let trailingPrepositions: Set<String> = [
        "about", "as", "at", "for", "from", "into", "just", "of", "really",
        "than", "to", "very", "with"
    ]

    private static let trailingAuxiliaries: Set<String> = [
        "are", "can", "could", "had", "has", "have", "is", "might", "must",
        "should", "was", "were", "will", "would"
    ]

    private static let pronounSubjects: Set<String> = [
        "he", "here", "i", "it", "one", "she", "so", "that", "there", "they",
        "this", "we", "what", "which", "who", "you"
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

    private static let complementIntroducingVerbs: Set<String> = [
        "are", "believe", "believes", "feel", "feels", "felt", "hope",
        "hoped", "hopes", "is", "know", "knows", "knew", "mean", "means",
        "meant", "said", "say", "says", "think", "thinks", "thought", "was",
        "were"
    ]

    private static let leadingDependentPhrases: [[String]] = [
        ["after"], ["although"], ["as", "long", "as"], ["as", "soon", "as"],
        ["because"], ["before"], ["even", "if"], ["even", "though"],
        ["especially", "when"], ["if"], ["once"], ["though"], ["unless"],
        ["until"], ["when"], ["whenever"], ["whereas"], ["while"]
    ]
}
