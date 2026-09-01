@preconcurrency import AppKit
import ApplicationServices
import Foundation

struct DictationRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let text: String
    let appName: String
    let duration: TimeInterval
    let wordsPerMinute: Int
}

struct InsertionRecovery: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let appName: String
}

enum DictationState: Equatable {
    case idle
    case listening
    case finishing
    case error(String)
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var state: DictationState = .idle
    @Published private(set) var liveText = ""
    @Published private(set) var committedText = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var records: [DictationRecord] = []
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var speechAuthorized = false
    @Published private(set) var accessibilityAuthorized = false
    @Published private(set) var isRequestingPermissions = false
    @Published private(set) var permissionRequestMessage: String?
    @Published private(set) var insertionRecovery: InsertionRecovery?
    @Published var selectedSection: SidebarSection = .home
    @Published var dictionary: [String] = [] { didSet { persistDictionary() } }
    @Published var useOnDeviceRecognition = true
    @Published var shortcut: ShortcutBinding = .standard {
        didSet {
            saveSettings()
            GlobalHotKey.shared.binding = shortcut
        }
    }
    @Published var barPlacement: BarPlacement = .bottom { didSet { saveSettings() } }
    @Published var barScale = 0.85 { didSet { saveSettings() } }
    @Published private(set) var freeBarX = 0.5
    @Published private(set) var freeBarY = 0.0
    @Published var characterDelayMilliseconds = 4.0 {
        didSet { injector.characterDelayMilliseconds = characterDelayMilliseconds }
    }

    private let speechEngine = AppleSpeechEngine()
    private let injector = KeystrokeInjector()
    private var stabilizer = TranscriptStabilizer(holdbackWords: 1)
    private var startedAt: Date?
    private var targetAppName = "Another app"
    private var insertionSnapshot: TextInsertionSnapshot?
    private var insertionVerificationTask: Task<Void, Never>?
    private var stopFallbackTask: Task<Void, Never>?

    var isListening: Bool { state == .listening || state == .finishing }
    var lastTranscript: String { records.first?.text ?? "" }
    var totalWords: Int { records.reduce(0) { $0 + $1.text.wordCount } }
    var averageWPM: Int {
        let valid = records.filter { $0.wordsPerMinute > 0 }
        guard !valid.isEmpty else { return 0 }
        return valid.reduce(0) { $0 + $1.wordsPerMinute } / valid.count
    }
    var currentDuration: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    private init() {
        records = Self.loadRecords()
        dictionary = UserDefaults.standard.stringArray(forKey: "customDictionary") ?? ["Cadence", "macOS", "SwiftUI"]
        characterDelayMilliseconds = UserDefaults.standard.object(forKey: "characterDelay") as? Double ?? 4
        useOnDeviceRecognition = UserDefaults.standard.object(forKey: "onDevice") as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: "shortcut"),
           let saved = try? JSONDecoder().decode(ShortcutBinding.self, from: data) {
            shortcut = saved
        }
        if let raw = UserDefaults.standard.string(forKey: "barPlacement"), let saved = BarPlacement(rawValue: raw) {
            barPlacement = saved
        }
        barScale = UserDefaults.standard.object(forKey: "barScale") as? Double ?? 0.85
        freeBarX = UserDefaults.standard.object(forKey: "freeBarX") as? Double ?? 0.5
        freeBarY = UserDefaults.standard.object(forKey: "freeBarY") as? Double ?? 0
        if UserDefaults.standard.integer(forKey: "floatingBarDesignVersion") < 2 {
            barPlacement = .bottom
            barScale = 0.85
            freeBarY = 0
            UserDefaults.standard.set(2, forKey: "floatingBarDesignVersion")
        }
        injector.characterDelayMilliseconds = characterDelayMilliseconds
    }

    func toggleDictation() {
        if isListening { stopDictation() } else { Task { await startDictation() } }
    }

    /// Starting from the Hub would otherwise leave Cadence as the key app and
    /// send synthetic keystrokes back into its own window. Hiding returns focus
    /// to the editor the user was working in before capture begins.
    func toggleFromHub() {
        if isListening {
            stopDictation()
        } else {
            NSApp.hide(nil)
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                await startDictation()
            }
        }
    }

    func startDictation() async {
        guard state == .idle || isError else { return }
        // A final recognition result can arrive faster than the last characters
        // are emitted. Never cancel that tail when a new session starts.
        await injector.waitUntilDrained()
        guard state == .idle || isError else { return }
        refreshPermissions()
        guard microphoneAuthorized, speechAuthorized else {
            state = .error("Microphone and Speech Recognition access are required.")
            selectedSection = .settings
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard accessibilityAuthorized else {
            requestAccessibilityPermission()
            state = .error("Enable Accessibility so Cadence can type into other apps.")
            selectedSection = .settings
            return
        }

        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Another app"
        if targetAppName == "Cadence" { targetAppName = "the last active editor" }
        liveText = ""
        committedText = ""
        stabilizer.reset()
        insertionVerificationTask?.cancel()
        insertionRecovery = nil
        injector.beginSession()
        insertionSnapshot = TextInsertionVerifier.capture()
        startedAt = Date()
        state = .listening

        do {
            try await speechEngine.start(
                contextualStrings: dictionary,
                requiresOnDeviceRecognition: useOnDeviceRecognition,
                onUpdate: { [weak self] update in
                    Task { @MainActor in self?.consume(update) }
                },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.audioLevel = level }
                }
            )
        } catch {
            state = .error(error.localizedDescription)
            startedAt = nil
            insertionSnapshot = nil
        }
    }

    func stopDictation() {
        guard isListening else { return }
        state = .finishing
        speechEngine.finish()
        stopFallbackTask?.cancel()
        stopFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.finalizeSession()
        }
    }

    func cancelDictation() {
        speechEngine.cancel()
        injector.cancelPending()
        state = .idle
        startedAt = nil
        liveText = ""
        committedText = ""
        audioLevel = 0
        stabilizer.reset()
        insertionSnapshot = nil
    }

    func requestPermissions() {
        guard !isRequestingPermissions else { return }
        isRequestingPermissions = true
        permissionRequestMessage = nil
        Task {
            _ = await AppleSpeechEngine.requestPermissions()
            refreshPermissions()
            if !accessibilityAuthorized { requestAccessibilityPermission() }
            isRequestingPermissions = false
            if !microphoneAuthorized || !speechAuthorized {
                permissionRequestMessage = "If access was previously denied, enable Cadence in System Settings → Privacy & Security."
            }
        }
    }

    func requestAccessibilityPermission() {
        // Use the documented option's string value directly. The SDK exposes the
        // constant as mutable global state, which Swift 6 correctly rejects here.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshPermissions() }
    }

    func refreshPermissions() {
        microphoneAuthorized = AppleSpeechEngine.microphoneAuthorized
        speechAuthorized = AppleSpeechEngine.speechAuthorized
        accessibilityAuthorized = AXIsProcessTrusted()
    }

    func addDictionaryTerm(_ term: String) {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !dictionary.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        dictionary.insert(clean, at: 0)
    }

    func removeDictionaryTerms(at offsets: IndexSet) { dictionary.remove(atOffsets: offsets) }

    func deleteRecord(_ record: DictationRecord) {
        records.removeAll { $0.id == record.id }
        persistRecords()
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyInsertionRecovery() {
        guard let recovery = insertionRecovery else { return }
        copy(recovery.text)
        insertionRecovery = nil
    }

    func dismissInsertionRecovery() {
        insertionRecovery = nil
    }

    func pasteLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        injector.enqueue(lastTranscript)
    }

    func saveSettings() {
        UserDefaults.standard.set(characterDelayMilliseconds, forKey: "characterDelay")
        UserDefaults.standard.set(useOnDeviceRecognition, forKey: "onDevice")
        if let data = try? JSONEncoder().encode(shortcut) { UserDefaults.standard.set(data, forKey: "shortcut") }
        UserDefaults.standard.set(barPlacement.rawValue, forKey: "barPlacement")
        UserDefaults.standard.set(barScale, forKey: "barScale")
    }

    func saveFreeBarPosition(x: Double, y: Double) {
        freeBarX = min(max(x, 0), 1)
        freeBarY = min(max(y, 0), 1)
        UserDefaults.standard.set(freeBarX, forKey: "freeBarX")
        UserDefaults.standard.set(freeBarY, forKey: "freeBarY")
    }

    func resetBarPosition() {
        saveFreeBarPosition(x: 0.5, y: 0)
        barPlacement = .bottom
        barScale = 0.85
    }

    private var isError: Bool { if case .error = state { return true }; return false }

    private func consume(_ update: SpeechUpdate) {
        guard isListening else { return }
        liveText = update.text
        let delta = stabilizer.consume(update.text, isFinal: update.isFinal)
        if !delta.isEmpty {
            committedText += delta
            injector.enqueue(delta)
        }
        if update.isFinal { finalizeSession() }
    }

    private func finalizeSession() {
        guard isListening else { return }
        stopFallbackTask?.cancel()
        let remaining = stabilizer.flush(liveText)
        if !remaining.isEmpty {
            committedText += remaining
            injector.enqueue(remaining)
        }
        speechEngine.cancel()
        let finalText = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let insertedText = committedText
        let snapshot = insertionSnapshot
        let completedTargetAppName = targetAppName
        insertionSnapshot = nil
        let duration = max(Date().timeIntervalSince(startedAt ?? Date()), 1)
        if !finalText.isEmpty {
            let record = DictationRecord(
                id: UUID(), date: Date(), text: finalText, appName: targetAppName,
                duration: duration, wordsPerMinute: Int((Double(finalText.wordCount) / duration) * 60)
            )
            records.insert(record, at: 0)
            records = Array(records.prefix(100))
            persistRecords()
        }
        state = .idle
        startedAt = nil
        audioLevel = 0
        liveText = ""
        committedText = ""
        stabilizer.reset()

        guard !finalText.isEmpty else { return }
        insertionVerificationTask?.cancel()
        insertionVerificationTask = Task { [weak self] in
            guard let self else { return }
            await injector.waitUntilDrained()
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let result = TextInsertionVerifier.verify(
                snapshot,
                insertedText: insertedText,
                postingFailed: injector.hadPostingFailure
            )
            if result == .failed {
                insertionRecovery = InsertionRecovery(text: finalText, appName: completedTargetAppName)
            }
        }
    }

    private func persistDictionary() {
        UserDefaults.standard.set(dictionary, forKey: "customDictionary")
    }

    private func persistRecords() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: "records") }
    }

    private static func loadRecords() -> [DictationRecord] {
        guard let data = UserDefaults.standard.data(forKey: "records"),
              let records = try? JSONDecoder().decode([DictationRecord].self, from: data) else { return [] }
        return records
    }
}

extension String {
    var wordCount: Int { split(whereSeparator: { $0.isWhitespace }).count }
}
