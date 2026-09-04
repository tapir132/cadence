import Foundation

struct CadenceBugReport: Codable, Equatable {
    struct Application: Codable, Equatable {
        let version: String
        let build: String
        let bundleIdentifier: String
    }

    struct System: Codable, Equatable {
        let operatingSystem: String
        let architecture: String
        var availableDiskSpaceBytes: Int64? = nil
    }

    struct Permissions: Codable, Equatable {
        let microphone: Bool
        let accessibility: Bool
    }

    struct Settings: Codable, Equatable {
        struct Shortcut: Codable, Equatable {
            let display: String
            let keyCode: UInt16?
            let modifierFlags: UInt
        }

        struct FloatingBar: Codable, Equatable {
            let placement: String
            let scale: Double
            let freePositionX: Double
            let freePositionY: Double
        }

        struct Updates: Codable, Equatable {
            let channel: String
            let checksAutomatically: Bool
            let downloadsAutomatically: Bool
        }

        let dictationProfile: String
        let recognitionProfile: String
        let autoCleanup: String
        let fillerWordCleanup: Bool
        let deeperEditing: Bool
        let stabilityBuffer: Bool
        let characterPlayback: Bool
        let characterPlaybackWordsPerMinute: Double
        let characterPlaybackRhythm: String
        let pausesMusic: Bool
        let shortcut: Shortcut
        let floatingBar: FloatingBar
        let updates: Updates
        let customDictionaryTermCount: Int
        let snippetCount: Int
        let writingStyles: [String: String]
    }

    struct Status: Codable, Equatable {
        let dictation: String
        let dictationError: String?
        let speechModel: String
        let speechModelError: String?
        let speechModelPreparationProgress: Double?
        let insertionRecoveryVisible: Bool
        let insertionRecoveryTargetApplication: String?
    }

    struct RecentDictation: Codable, Equatable {
        let date: Date
        let text: String
        let targetApplication: String
        let durationSeconds: TimeInterval
        let wordsPerMinute: Int
        let insertionVerification: String?
    }

    static let transcriptLimit = 3
    static let privacyNotice = "Contains the three most recent Cadence transcripts. It does not include audio, clipboard contents, dictionary terms, snippet text, or text surrounding the insertion point."

    let reportFormatVersion: Int
    let generatedAt: Date
    let privacy: String
    let application: Application
    let system: System
    let permissions: Permissions
    let settings: Settings
    let status: Status
    let recentDictations: [RecentDictation]

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func suggestedFilename(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Cadence-Bug-Report-\(formatter.string(from: date)).json"
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
