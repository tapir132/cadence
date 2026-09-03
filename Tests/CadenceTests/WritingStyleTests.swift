import Foundation
import Testing
@testable import Cadence

@Test func writingContextIsDetectedFromBundlesAndBrowserTabs() {
    #expect(WritingContext.detect(bundleIdentifier: "com.apple.MobileSMS", windowTitle: nil) == .personalMessages)
    #expect(WritingContext.detect(bundleIdentifier: "com.tinyspeck.slackmacgap", windowTitle: nil) == .workMessages)
    #expect(WritingContext.detect(bundleIdentifier: "com.apple.mail", windowTitle: nil) == .email)
    #expect(WritingContext.detect(bundleIdentifier: "com.apple.Terminal", windowTitle: "Gmail notes") == .other)
    #expect(WritingContext.detect(bundleIdentifier: "com.google.Chrome", windowTitle: "Inbox (3) - liam@example.com - Gmail") == .email)
    #expect(WritingContext.detect(bundleIdentifier: "com.apple.Safari", windowTitle: "(2) Feed | LinkedIn") == .workMessages)
    #expect(WritingContext.detect(bundleIdentifier: "com.apple.Safari", windowTitle: "WhatsApp") == .personalMessages)
    #expect(WritingContext.detect(bundleIdentifier: "com.apple.Safari", windowTitle: "Slackware Linux") == .other)
    #expect(WritingContext.detect(bundleIdentifier: nil, windowTitle: "Gmail") == .other)
}

@Test func writingStylePreferencesRoundTripAndRejectTonesTheContextDoesNotOffer() throws {
    let suiteName = "app.cadence.tests.styles.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(WritingStylePreferences.load(from: defaults).tone(for: .personalMessages) == .formal)
    var preferences = WritingStylePreferences.defaults
    preferences.tones[.personalMessages] = .veryCasual
    preferences.tones[.email] = .veryCasual
    preferences.save(to: defaults)
    let loaded = WritingStylePreferences.load(from: defaults)
    #expect(loaded.tone(for: .personalMessages) == .veryCasual)
    #expect(loaded.tone(for: .email) == .formal)
    #expect(WritingContext.personalMessages.tones == [.formal, .casual, .veryCasual])
    #expect(WritingContext.email.tones == [.formal, .casual, .excited])
}

@Test func tonePreviewsMatchTheFormatterRules() {
    #expect(WritingTone.formal.sample(for: .personalMessages)
        == "Hey, are you free for lunch tomorrow? Let’s do 12 if that works for you.")
    #expect(WritingTone.casual.sample(for: .personalMessages)
        == "Hey are you free for lunch tomorrow? Let’s do 12 if that works for you")
    #expect(WritingTone.veryCasual.sample(for: .personalMessages)
        == "hey are you free for lunch tomorrow? let’s do 12 if that works for you")
    #expect(WritingTone.excited.sample(for: .workMessages)
        == "Hey, if you’re free, let’s chat about the great results!")
    #expect(WritingTone.casual.sample(for: .email)
        == "Hi Alex,\n\nIt was great talking with you today. Looking forward to our next chat.")
    #expect(WritingTone.casual.sample(for: .other)
        == "So far I am enjoying the new workout routine.\n\nI am excited for tomorrow’s workout especially after a full night of rest.")
}

@Test func droppingCommasKeepsNumbersLineEndingsAndSpokenCommands() {
    #expect(WritingStyleFormatter.droppingCommas("Hey, are you free, or not?") == "Hey are you free or not?")
    #expect(WritingStyleFormatter.droppingCommas("It costs 1,000 dollars, roughly") == "It costs 1,000 dollars roughly")
    #expect(WritingStyleFormatter.droppingCommas("Hi Alex,\nthanks") == "Hi Alex,\nthanks")
    #expect(WritingStyleFormatter.droppingCommas("Hi Alex, new paragraph thanks") == "Hi Alex, new paragraph thanks")
    #expect(WritingStyleFormatter.droppingCommas("First, comma second") == "First comma second")
}

@Test func lowercasingSentenceStartsKeepsIFormsNamesFromTheDictionaryAndMixedCase() {
    #expect(
        WritingStyleFormatter.lowercasingSentenceStarts(
            "Hey there. I’m fine! Liam said hi. McDonald was closed? IPhone",
            preserving: ["Liam"]
        ) == "hey there. I’m fine! Liam said hi. McDonald was closed? IPhone"
    )
    #expect(
        WritingStyleFormatter.lowercasingSentenceStarts("Hello. World", preserving: [], includingFirstWord: false)
            == "Hello. world"
    )
}

@Test func casualMessagingDropsModelCommasAndTheClosingPeriodOnly() throws {
    var emitter = LiveTranscriptEmitter(style: WritingStyle(tone: .casual, context: .personalMessages))
    var inserted = ""
    inserted += try emitter.consume("Hey, are")?.insertion ?? ""
    inserted += try emitter.consume("Hey, are you free")?.insertion ?? ""
    #expect(inserted == "Hey are you")
    inserted += try emitter.finalize("Hey, are you free tomorrow?", continuesAfterPause: true)?.insertion ?? ""
    #expect(inserted == "Hey are you free tomorrow?")
    inserted += try emitter.consume("Let's do twelve comma if that works")?.insertion ?? ""
    let final = try #require(try emitter.finalize("Let's do twelve comma if that works", continuesAfterPause: false))
    inserted += final.insertion
    #expect(inserted == "Hey are you free tomorrow? Let's do twelve, if that works")
    #expect(final.transcript == inserted)
    #expect(emitter.finishDictation() == nil)
}

@Test func casualEmailKeepsPeriodsAndSpokenPeriodsSurviveEverywhere() throws {
    var email = LiveTranscriptEmitter(style: WritingStyle(tone: .casual, context: .email))
    let emailFinal = try #require(try email.finalize("Thanks for today", continuesAfterPause: false))
    #expect(emailFinal.transcript == "Thanks for today.")

    var chat = LiveTranscriptEmitter(style: WritingStyle(tone: .casual, context: .workMessages))
    let spoken = try #require(try chat.finalize("Ship it period", continuesAfterPause: false))
    #expect(spoken.transcript == "Ship it.")
    #expect(chat.finishDictation() == nil)
}

@Test func veryCasualLowercasesSentenceStartsAcrossSegmentsButNotDictionaryTerms() throws {
    var emitter = LiveTranscriptEmitter(
        dictionaryTerms: ["Liam"],
        style: WritingStyle(tone: .veryCasual, context: .personalMessages)
    )
    var inserted = ""
    inserted += try emitter.consume("Hey Liam. Are you")?.insertion ?? ""
    #expect(inserted == "hey Liam. are")
    inserted += try emitter.finalize("Hey Liam. Are you around", continuesAfterPause: true)?.insertion ?? ""
    inserted += try emitter.consume("Liam is here")?.insertion ?? ""
    inserted += try emitter.finalize("Liam is here", continuesAfterPause: true)?.insertion ?? ""
    inserted += try emitter.consume("I think so")?.insertion ?? ""
    inserted += try emitter.finalize("I think so", continuesAfterPause: false)?.insertion ?? ""
    #expect(inserted == "hey Liam. are you around. Liam is here. I think so")
}

@Test func excitedToneReplacesOnlyTheClosingPeriod() throws {
    var emitter = LiveTranscriptEmitter(style: WritingStyle(tone: .excited, context: .workMessages))
    var inserted = ""
    inserted += try emitter.finalize("Great results today", continuesAfterPause: true)?.insertion ?? ""
    inserted += try emitter.consume("Let's celebrate")?.insertion ?? ""
    inserted += try emitter.finalize("Let's celebrate", continuesAfterPause: false)?.insertion ?? ""
    #expect(inserted == "Great results today. Let's celebrate!")

    var question = LiveTranscriptEmitter(style: WritingStyle(tone: .excited, context: .other))
    #expect(try question.finalize("Are you in", continuesAfterPause: false)?.transcript == "Are you in!")
    var ready = LiveTranscriptEmitter(style: WritingStyle(tone: .excited, context: .other))
    #expect(try ready.finalize("Ready?", continuesAfterPause: false)?.transcript == "Ready?")
}

@Test func releasingAfterAPauseRetractsTheAutomaticPeriodForCasualAndExcitedTones() throws {
    var casual = LiveTranscriptEmitter(style: WritingStyle(tone: .casual, context: .personalMessages))
    var inserted = try casual.finalize("See you soon", continuesAfterPause: true)?.insertion ?? ""
    #expect(inserted == "See you soon.")
    let casualRetraction = casual.finishDictation()
    let retraction = try #require(casualRetraction)
    #expect(retraction.deleteBackward == 1)
    #expect(retraction.insertion == "")
    inserted = String(inserted.dropLast(retraction.deleteBackward)) + retraction.insertion
    #expect(inserted == "See you soon")
    #expect(retraction.transcript == inserted)
    #expect(casual.finishDictation() == nil)

    var excited = LiveTranscriptEmitter(style: WritingStyle(tone: .excited, context: .email))
    _ = try excited.finalize("See you soon", continuesAfterPause: true)
    let excitedRetraction = excited.finishDictation()
    let exclaimed = try #require(excitedRetraction)
    #expect(exclaimed.deleteBackward == 1)
    #expect(exclaimed.insertion == "!")
    #expect(exclaimed.transcript == "See you soon!")

    var formal = LiveTranscriptEmitter()
    _ = try formal.finalize("See you soon", continuesAfterPause: true)
    #expect(formal.finishDictation() == nil)

    var spoken = LiveTranscriptEmitter(style: WritingStyle(tone: .casual, context: .personalMessages))
    _ = try spoken.finalize("See you soon period", continuesAfterPause: true)
    #expect(spoken.finishDictation() == nil)
}

@Test func autoCleanupLevelPersistsThroughTheOriginalPreferenceKeys() throws {
    let suiteName = "app.cadence.tests.cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(AutoCleanupLevel.load(from: defaults) == .none)
    // A person who had Essay's two switches on before the single control
    // existed lands on Medium without any migration step.
    defaults.set(true, forKey: "speechCleanupEnabled")
    defaults.set(true, forKey: "deepEditingEnabled")
    #expect(AutoCleanupLevel.load(from: defaults) == .medium)
    AutoCleanupLevel.light.save(to: defaults)
    #expect(AutoCleanupLevel.load(from: defaults) == .light)
    #expect(!defaults.bool(forKey: "deepEditingEnabled"))
}

@Test func autoCleanupLevelMirrorsTheTwoCleanupSwitches() {
    #expect(AutoCleanupLevel(speechCleanupEnabled: false, deepEditingEnabled: false) == .none)
    #expect(AutoCleanupLevel(speechCleanupEnabled: true, deepEditingEnabled: false) == .light)
    #expect(AutoCleanupLevel(speechCleanupEnabled: true, deepEditingEnabled: true) == .medium)
    #expect(AutoCleanupLevel.medium.speechCleanupEnabled && AutoCleanupLevel.medium.deepEditingEnabled)
    #expect(!AutoCleanupLevel.none.speechCleanupEnabled)
    #expect(AutoCleanupLevel(speechCleanupEnabled: false, deepEditingEnabled: true) == .medium)
}
