import Foundation

/// The kind of app the cursor is in when dictation starts. Cadence recognizes
/// a category from the frontmost bundle identifier and, inside a browser, from
/// the focused tab title. Everything unrecognized is `other`.
enum WritingContext: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case personalMessages
    case workMessages
    case email
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personalMessages: "Personal messages"
        case .workMessages: "Work messages"
        case .email: "Email"
        case .other: "Other"
        }
    }

    var banner: String {
        switch self {
        case .personalMessages: "This style applies in personal messengers"
        case .workMessages: "This style applies in workplace messengers"
        case .email: "This style applies in all major email apps"
        case .other: "This style applies in all other apps"
        }
    }

    var exampleApps: String {
        switch self {
        case .personalMessages: "Messages, WhatsApp, Telegram, Discord, Signal, Instagram"
        case .workMessages: "Slack, Microsoft Teams, LinkedIn, Google Chat, Zoom"
        case .email: "Mail, Gmail, Outlook, Spark, Superhuman, Mimestream"
        case .other: "Editors, notes, documents, terminals, and AI chats"
        }
    }

    /// Ending a chat message without a period is the casual convention; email
    /// and documents keep their periods even when casual.
    var isMessaging: Bool { self == .personalMessages || self == .workMessages }

    var tones: [WritingTone] {
        self == .personalMessages
            ? [.formal, .casual, .veryCasual]
            : [.formal, .casual, .excited]
    }

    static func detect(bundleIdentifier: String?, windowTitle: String?) -> WritingContext {
        guard let bundleIdentifier else { return .other }
        if let known = bundleCategories[bundleIdentifier] { return known }
        let isBrowser = browserBundlePrefixes.contains { bundleIdentifier.hasPrefix($0) }
        guard isBrowser, let windowTitle else { return .other }
        for (context, names) in titleCategories {
            for name in names where windowTitle.range(
                of: "(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: name))(?![\\p{L}\\p{N}])",
                options: .regularExpression
            ) != nil {
                return context
            }
        }
        return .other
    }

    // ponytail: fixed tables; a per-category “add this app” list can layer on top later.
    private static let bundleCategories: [String: WritingContext] = [
        "com.apple.MobileSMS": .personalMessages,
        "net.whatsapp.WhatsApp": .personalMessages,
        "ru.keepcoder.Telegram": .personalMessages,
        "org.telegram.desktop": .personalMessages,
        "com.hnc.Discord": .personalMessages,
        "org.whispersystems.signal-desktop": .personalMessages,
        "com.facebook.archon": .personalMessages,
        "com.automattic.beeper.desktop": .personalMessages,
        "com.tencent.xinWeChat": .personalMessages,
        "com.viber.osx": .personalMessages,
        "com.tinyspeck.slackmacgap": .workMessages,
        "com.microsoft.teams2": .workMessages,
        "com.microsoft.teams": .workMessages,
        "us.zoom.xos": .workMessages,
        "Mattermost.Desktop": .workMessages,
        "chat.rocket": .workMessages,
        "Cisco-Systems.Spark": .workMessages,
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.readdle.SparkDesktop": .email,
        "com.superhuman.electron": .email,
        "com.superhuman.Superhuman": .email,
        "com.mimestream.Mimestream": .email,
        "org.mozilla.thunderbird": .email,
        "ch.protonmail.desktop": .email,
        "it.bloop.airmail2": .email,
        "io.canarymail.mac": .email,
        "com.postbox-inc.postbox": .email
    ]

    /// Web apps are recognized from the tab title only inside a browser or a
    /// browser-installed web app, so a document titled “Gmail notes” in an
    /// editor stays in its own category.
    private static let browserBundlePrefixes = [
        "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser",
        "com.vivaldi.Vivaldi", "com.operasoftware", "org.chromium.Chromium",
        "com.kagi.kagimacOS", "ai.perplexity.comet", "com.sigmaos"
    ]

    private static let titleCategories: [(WritingContext, [String])] = [
        (.personalMessages, ["WhatsApp", "Telegram", "Discord", "Instagram", "Messenger", "Snapchat"]),
        (.workMessages, ["Slack", "Microsoft Teams", "LinkedIn", "Google Chat", "Zoom", "Mattermost", "Webex"]),
        (.email, ["Gmail", "Outlook", "Yahoo Mail", "Proton Mail", "Fastmail", "iCloud Mail", "Superhuman", "HEY"])
    ]
}

enum WritingTone: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case formal
    case casual
    case veryCasual
    case excited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .formal: "Formal."
        case .casual: "Casual"
        case .veryCasual: "very casual"
        case .excited: "Excited!"
        }
    }

    var subtitle: String {
        switch self {
        case .formal: "Caps + Punctuation"
        case .casual: "Caps + Less punctuation"
        case .veryCasual: "No caps + Less punctuation"
        case .excited: "More exclamations"
        }
    }

    /// Runs the real formatter over a formal sentence so the preview never
    /// promises a change Cadence does not make.
    func sample(for context: WritingContext) -> String {
        let formal: String
        switch context {
        case .personalMessages:
            formal = "Hey, are you free for lunch tomorrow? Let’s do 12 if that works for you."
        case .workMessages:
            formal = "Hey, if you’re free, let’s chat about the great results."
        case .email:
            formal = "Hi Alex,\n\nIt was great talking with you today. Looking forward to our next chat."
        case .other:
            formal = "So far, I am enjoying the new workout routine.\n\nI am excited for tomorrow’s workout, especially after a full night of rest."
        }
        let style = WritingStyle(tone: self, context: context)
        var text = style.dropsModelCommas ? WritingStyleFormatter.droppingCommas(formal) : formal
        if style.lowercasesSentenceStarts {
            text = WritingStyleFormatter.lowercasingSentenceStarts(text, preserving: [])
        }
        return WritingStyleFormatter.closingDictation(text, style: style)
    }
}

/// The formatting rules in effect for one dictation. A tone changes only
/// punctuation and capitalization; it never rewrites words.
struct WritingStyle: Equatable, Sendable {
    let tone: WritingTone
    let context: WritingContext

    static let standard = WritingStyle(tone: .formal, context: .other)

    var dropsModelCommas: Bool { tone == .casual || tone == .veryCasual }
    var lowercasesSentenceStarts: Bool { tone == .veryCasual }
    var dropsFinalPeriod: Bool { dropsModelCommas && context.isMessaging }
    var exclaimsFinalSentence: Bool { tone == .excited }
    var changesClosingPeriod: Bool { dropsFinalPeriod || exclaimsFinalSentence }
}

struct WritingStylePreferences: Equatable, Sendable {
    static let key = "writingStyles"
    static let defaults = WritingStylePreferences(tones: [:])

    var tones: [WritingContext: WritingTone]

    func tone(for context: WritingContext) -> WritingTone {
        let saved = tones[context] ?? .formal
        return context.tones.contains(saved) ? saved : .formal
    }

    func style(for context: WritingContext) -> WritingStyle {
        WritingStyle(tone: tone(for: context), context: context)
    }

    static func load(from defaults: UserDefaults) -> WritingStylePreferences {
        guard let raw = defaults.dictionary(forKey: key) as? [String: String] else { return .defaults }
        var tones: [WritingContext: WritingTone] = [:]
        for (contextRaw, toneRaw) in raw {
            guard let context = WritingContext(rawValue: contextRaw),
                  let tone = WritingTone(rawValue: toneRaw) else { continue }
            tones[context] = tone
        }
        return WritingStylePreferences(tones: tones)
    }

    func save(to defaults: UserDefaults) {
        var raw: [String: String] = [:]
        for (context, tone) in tones { raw[context.rawValue] = tone.rawValue }
        defaults.set(raw, forKey: Self.key)
    }
}

/// Pure text rules shared by the live emitter and the Style previews.
enum WritingStyleFormatter {
    /// Removes recognizer-supplied commas. Digit groups such as 1,000 and a
    /// comma that ends a line (a greeting or sign-off) keep theirs. Spoken
    /// “comma” commands are converted after this step, so they always survive.
    static func droppingCommas(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?<!\d),(?!\d|[ \t]*(?:\n|(?i:new[ \t-]+(?:line|paragraph))\b))[ \t]*"#,
            with: " ",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"[ \t]+(?=[.!?;:\n]|$)"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }

    /// Lowercases a plainly capitalized word at each sentence start. `I` and
    /// its contractions, mixed-case words such as iPhone, and saved dictionary
    /// terms keep their case.
    static func lowercasingSentenceStarts(
        _ text: String,
        preserving dictionaryTerms: [String],
        includingFirstWord: Bool = true
    ) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(^|[.!?]["'”’)\]]*[ \t\n]+|\n)([\p{Lu}][\p{Ll}]*(?:['’][\p{Ll}]+)*)(?![\p{L}'’])"#
        ) else { return text }
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let wordRange = Range(match.range(at: 2), in: text) else { continue }
            if !includingFirstWord, match.range(at: 1).length == 0 { continue }
            let word = String(text[wordRange])
            guard let lowered = loweredPlainWord(word, preserving: dictionaryTerms) else { continue }
            result.replaceSubrange(wordRange, with: lowered)
        }
        return result
    }

    /// Lowercases only the leading word, used after Cadence retracts a period
    /// and joins the new words onto the previous sentence.
    static func lowercasingFirstWord(_ text: String, preserving dictionaryTerms: [String]) -> String {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }), text[first].isLetter else { return text }
        let end = text[first...].firstIndex(where: { !$0.isLetter && $0 != "'" && $0 != "’" }) ?? text.endIndex
        guard let lowered = loweredPlainWord(String(text[first..<end]), preserving: dictionaryTerms) else {
            return text
        }
        var result = text
        result.replaceSubrange(first..<end, with: lowered)
        return result
    }

    /// Applies the tone's rule for the last sentence of a dictation to text
    /// that already carries normal sentence punctuation.
    static func closingDictation(_ text: String, style: WritingStyle) -> String {
        guard style.changesClosingPeriod, text.last == "." else { return text }
        var result = text
        result.removeLast()
        if style.exclaimsFinalSentence { result.append("!") }
        return result
    }

    private static func loweredPlainWord(_ word: String, preserving dictionaryTerms: [String]) -> String? {
        guard let first = word.first, first.isUppercase,
              !word.dropFirst().contains(where: \.isUppercase),
              !preservedCapitals.contains(word),
              !dictionaryTerms.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame })
        else { return nil }
        return word.prefix(1).lowercased() + word.dropFirst()
    }

    private static let preservedCapitals: Set<String> = [
        "I", "I'm", "I’m", "I'll", "I’ll", "I've", "I’ve", "I'd", "I’d"
    ]
}
