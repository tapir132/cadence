import Foundation

/// Converts revisable partial ASR hypotheses into append-only text.
/// A word is committed only after it survives a second hypothesis, with a small
/// tail held back so the recognizer can still revise the newest phrase.
struct TranscriptStabilizer {
    private(set) var committedTokens: [String] = []
    private var previousTokens: [String] = []
    let holdbackWords: Int

    init(holdbackWords: Int = 1) {
        self.holdbackWords = max(0, holdbackWords)
    }

    mutating func consume(_ hypothesis: String, isFinal: Bool) -> String {
        let tokens = Self.tokens(in: hypothesis)
        guard !tokens.isEmpty else {
            previousTokens = tokens
            return ""
        }

        let matchesCommitted = Self.commonPrefixCount(tokens, committedTokens) == committedTokens.count
        guard matchesCommitted else {
            previousTokens = tokens
            return ""
        }

        let stablePrefix = isFinal ? tokens.count : Self.commonPrefixCount(tokens, previousTokens)
        let safeCount = isFinal ? tokens.count : max(committedTokens.count, stablePrefix - holdbackWords)
        let clampedCount = min(tokens.count, safeCount)
        guard clampedCount > committedTokens.count else {
            previousTokens = tokens
            return ""
        }

        let newTokens = Array(tokens[committedTokens.count..<clampedCount])
        let delta = Self.render(newTokens, hasExistingText: !committedTokens.isEmpty)
        committedTokens.append(contentsOf: newTokens)
        previousTokens = tokens
        return delta
    }

    mutating func flush(_ hypothesis: String) -> String {
        consume(hypothesis, isFinal: true)
    }

    mutating func reset() {
        committedTokens.removeAll(keepingCapacity: true)
        previousTokens.removeAll(keepingCapacity: true)
    }

    static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func commonPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
        var index = 0
        while index < lhs.count, index < rhs.count,
              lhs[index].caseInsensitiveCompare(rhs[index]) == .orderedSame {
            index += 1
        }
        return index
    }

    static func render(_ tokens: [String], hasExistingText: Bool) -> String {
        guard !tokens.isEmpty else { return "" }
        return (hasExistingText ? " " : "") + tokens.joined(separator: " ")
    }
}
