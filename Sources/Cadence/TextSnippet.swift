import Foundation

struct TextSnippet: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let trigger: String
    let replacement: String
    let createdAt: Date
    let updatedAt: Date
}

enum TextSnippetValidationError: LocalizedError, Equatable {
    case triggerRequired
    case replacementRequired
    case triggerTooLong
    case replacementTooLong
    case reservedTrigger
    case duplicateTrigger(String)
    case overlappingTrigger(String)

    var errorDescription: String? {
        switch self {
        case .triggerRequired:
            "Enter the phrase you want to say."
        case .replacementRequired:
            "Enter the text Cadence should insert."
        case .triggerTooLong:
            "Spoken triggers can be up to \(TextSnippetValidator.triggerLimit) characters."
        case .replacementTooLong:
            "Snippet text can be up to \(TextSnippetValidator.replacementLimit) characters."
        case .reservedTrigger:
            "Choose a trigger that doesn’t contain a spoken punctuation command such as “period” or “question mark”."
        case let .duplicateTrigger(trigger):
            "“\(trigger)” is already a snippet trigger."
        case let .overlappingTrigger(trigger):
            "This conflicts with “\(trigger)”. Neither trigger can begin with the complete other trigger."
        }
    }
}

enum TextSnippetValidator {
    static let triggerLimit = 80
    static let replacementLimit = 4_000

    static func cleanedTrigger(_ trigger: String) -> String {
        trigger
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func cleanedReplacement(_ replacement: String) -> String {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(
        trigger: String,
        replacement: String,
        among snippets: [TextSnippet],
        excluding excludedID: UUID? = nil
    ) -> TextSnippetValidationError? {
        let cleanTrigger = cleanedTrigger(trigger)
        let cleanReplacement = cleanedReplacement(replacement)
        guard !cleanTrigger.isEmpty else { return .triggerRequired }
        guard !cleanReplacement.isEmpty else { return .replacementRequired }
        guard cleanTrigger.count <= triggerLimit else { return .triggerTooLong }
        guard cleanReplacement.count <= replacementLimit else { return .replacementTooLong }
        guard SpokenPunctuationFormatter.format(cleanTrigger) == cleanTrigger else {
            return .reservedTrigger
        }

        let proposedWords = foldedWords(in: cleanTrigger)
        for snippet in snippets where snippet.id != excludedID {
            let existingTrigger = cleanedTrigger(snippet.trigger)
            let existingWords = foldedWords(in: existingTrigger)
            if proposedWords == existingWords {
                return .duplicateTrigger(existingTrigger)
            }
            if isPrefix(proposedWords, of: existingWords)
                || isPrefix(existingWords, of: proposedWords) {
                return .overlappingTrigger(existingTrigger)
            }
        }
        return nil
    }

    static func foldedWords(in trigger: String) -> [String] {
        cleanedTrigger(trigger)
            .split(separator: " ")
            .map { folded(String($0)) }
    }

    static func folded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func isPrefix(_ prefix: [String], of words: [String]) -> Bool {
        guard prefix.count < words.count else { return false }
        return zip(prefix, words).allSatisfy(==)
    }
}
