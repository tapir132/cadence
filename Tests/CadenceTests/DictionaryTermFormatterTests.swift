import Testing
@testable import Cadence

@Test func dictionaryRestoresExactCaseAndDiacritics() {
    let result = DictionaryTermFormatter.apply(
        to: "jose arcadio buendia appears beside MACOS",
        terms: ["José Arcadio Buendía", "macOS"]
    )
    #expect(result == "José Arcadio Buendía appears beside macOS")
}

@Test func dictionaryNeverFuzzilyInventsNearbyWords() {
    let result = DictionaryTermFormatter.apply(
        to: "Jose Art Gardio Buendia and concatenate",
        terms: ["José Arcadio Buendía", "Cadence"]
    )
    #expect(result == "Jose Art Gardio Buendia and concatenate")
}

@Test func dictionaryMatchesOnlyWholeWordsAndPhrases() {
    let result = DictionaryTermFormatter.apply(
        to: "cadence Cadenceful pre-cadence",
        terms: ["Cadence"]
    )
    #expect(result == "Cadence Cadenceful pre-Cadence")
}
