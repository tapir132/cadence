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
    @Published private(set) var accessibilityAuthorized = false
    @Published private(set) var speechModelStatus: SpeechModelStatus = .preparing(progress: nil)
    @Published private(set) var isRequestingPermissions = false
    @Published private(set) var permissionRequestMessage: String?
    @Published private(set) var insertionRecovery: InsertionRecovery?
    @Published var selectedSection: SidebarSection = .home
    @Published var dictionary: [String] = [] { didSet { persistDictionary() } }
    @Published private(set) var snippets: [TextSnippet] = [] { didSet { persistSnippets() } }
    @Published var shortcut: ShortcutBinding = .standard {
        didSet {
            saveSettings()
            GlobalHotKey.shared.binding = shortcut
        }
    }
    @Published var barPlacement: BarPlacement = .bottom { didSet { saveSettings() } }
    @Published var barScale = 0.85 { didSet { saveSettings() } }
    @Published var recognitionProfile: RecognitionProfile = .fast {
        didSet {
            saveSettings()
            guard recognitionProfile != oldValue else { return }
            speechModelStatus = .preparing(progress: nil)
            Task { [weak self] in await self?.prepareSpeechModel() }
        }
    }
    @Published var speechCleanupEnabled = false { didSet { saveSettings() } }
    @Published var typingBufferEnabled = false { didSet { saveSettings() } }
    @Published private(set) var freeBarX = 0.5
    @Published private(set) var freeBarY = 0.0

    private let speechEngine = AudioCaptureEngine()
    private let transcriber = LiveSpeechTranscriber()
    private let injector = KeystrokeInjector()
    private let snippetStore = TextSnippetStore()
    private var startedAt: Date?
    private var targetAppName = "Another app"
    private var insertionSnapshot: TextInsertionSnapshot?
    private var insertionVerificationTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?

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
        snippets = loadSnippetsAndMigrateDefaults()
        if let data = UserDefaults.standard.data(forKey: "shortcut"),
           let saved = try? JSONDecoder().decode(ShortcutBinding.self, from: data) {
            shortcut = saved
        }
        if let raw = UserDefaults.standard.string(forKey: "barPlacement"), let saved = BarPlacement(rawValue: raw) {
            barPlacement = saved
        }
        barScale = UserDefaults.standard.object(forKey: "barScale") as? Double ?? 0.85
        if let raw = UserDefaults.standard.string(forKey: "recognitionProfile"),
           let saved = RecognitionProfile(rawValue: raw) {
            recognitionProfile = saved
        }
        speechCleanupEnabled = UserDefaults.standard.bool(forKey: "speechCleanupEnabled")
        typingBufferEnabled = UserDefaults.standard.bool(forKey: "typingBufferEnabled")
        freeBarX = UserDefaults.standard.object(forKey: "freeBarX") as? Double ?? 0.5
        freeBarY = UserDefaults.standard.object(forKey: "freeBarY") as? Double ?? 0
        if UserDefaults.standard.integer(forKey: "floatingBarDesignVersion") < 2 {
            barPlacement = .bottom
            barScale = 0.85
            freeBarY = 0
            UserDefaults.standard.set(2, forKey: "floatingBarDesignVersion")
        }
        Task { [weak self] in await self?.prepareSpeechModel() }
    }

    func toggleDictation() {
        if isListening { stopDictation() } else { Task { await startDictation() } }
    }

    /// Hold-to-talk: the shortcut starts dictation while held and stops it on
    /// release, even when the release lands before the engine has started.
    func shortcutPressed() {
        shortcutHeld = true
        guard !isListening else { return }
        Task {
            await startDictation()
            if !shortcutHeld { stopDictation() }
        }
    }

    func shortcutReleased() {
        shortcutHeld = false
        stopDictation()
    }

    private var shortcutHeld = false

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
        // Command-V is delivered asynchronously. Never replace its pasteboard
        // value by starting a new session before the prior paste drains.
        await injector.waitUntilDrained()
        guard state == .idle || isError else { return }
        refreshPermissions()
        guard microphoneAuthorized else {
            state = .error("Microphone access is required.")
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
        guard speechModelStatus == .ready else {
            switch speechModelStatus {
            case .preparing:
                state = .error("Cadence is preparing its local speech model. Try again when Settings shows Ready.")
            case let .failed(message):
                state = .error("The local speech model could not load: \(message)")
            case .ready:
                break
            }
            selectedSection = .settings
            return
        }

        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Another app"
        if targetAppName == "Cadence" { targetAppName = "the last active editor" }
        liveText = ""
        committedText = ""
        insertionVerificationTask?.cancel()
        insertionRecovery = nil
        insertionSnapshot = TextInsertionVerifier.capture()
        injector.beginSession(target: insertionSnapshot)
        startedAt = Date()
        state = .listening

        do {
            let audio = try speechEngine.start { [weak self] level in
                Task { @MainActor in self?.audioLevel = level }
            }
            transcriptionTask?.cancel()
            let cleanupEnabled = speechCleanupEnabled
            let dictionaryTerms = dictionary
            let snippetSnapshot = snippets
            let insertionDelay: Duration = typingBufferEnabled ? .seconds(1) : .zero
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let text = try await transcriber.transcribe(
                        audio,
                        cleanupEnabled: cleanupEnabled,
                        dictionaryTerms: dictionaryTerms,
                        snippets: snippetSnapshot,
                        insertionDelay: insertionDelay
                    ) { [weak self] update in
                        await self?.consume(update)
                    }
                    guard !Task.isCancelled else { return }
                    completeTranscription(text)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    failTranscription(error)
                }
            }
        } catch {
            speechEngine.cancel()
            state = .error(error.localizedDescription)
            startedAt = nil
            insertionSnapshot = nil
        }
    }

    func stopDictation() {
        guard state == .listening else { return }
        state = .finishing
        audioLevel = 0
        speechEngine.finish()
    }

    func cancelDictation() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        speechEngine.cancel()
        injector.cancelPending()
        state = .idle
        startedAt = nil
        liveText = ""
        committedText = ""
        audioLevel = 0
        insertionSnapshot = nil
    }

    func requestPermissions() {
        guard !isRequestingPermissions else { return }
        isRequestingPermissions = true
        permissionRequestMessage = nil
        Task {
            _ = await AudioCaptureEngine.requestPermissions()
            refreshPermissions()
            if !accessibilityAuthorized { requestAccessibilityPermission() }
            isRequestingPermissions = false
            if !microphoneAuthorized {
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
        // Polled while Settings is visible; only publish real changes.
        let microphone = AudioCaptureEngine.microphoneAuthorized
        let accessibility = AXIsProcessTrusted()
        if microphone != microphoneAuthorized { microphoneAuthorized = microphone }
        if accessibility != accessibilityAuthorized { accessibilityAuthorized = accessibility }
    }

    func retrySpeechModelPreparation() {
        Task { [weak self] in await self?.prepareSpeechModel() }
    }

    func addDictionaryTerm(_ term: String) {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !dictionary.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
        dictionary.insert(clean, at: 0)
    }

    func removeDictionaryTerms(at offsets: IndexSet) { dictionary.remove(atOffsets: offsets) }

    @discardableResult
    func saveSnippet(
        id: UUID?,
        trigger: String,
        replacement: String
    ) -> TextSnippetValidationError? {
        if let error = TextSnippetValidator.validate(
            trigger: trigger,
            replacement: replacement,
            among: snippets,
            excluding: id
        ) {
            return error
        }

        let cleanTrigger = TextSnippetValidator.cleanedTrigger(trigger)
        let cleanReplacement = TextSnippetValidator.cleanedReplacement(replacement)
        let now = Date()
        if let id, let index = snippets.firstIndex(where: { $0.id == id }) {
            let previous = snippets[index]
            snippets[index] = TextSnippet(
                id: previous.id,
                trigger: cleanTrigger,
                replacement: cleanReplacement,
                createdAt: previous.createdAt,
                updatedAt: now
            )
        } else {
            snippets.insert(
                TextSnippet(
                    id: UUID(),
                    trigger: cleanTrigger,
                    replacement: cleanReplacement,
                    createdAt: now,
                    updatedAt: now
                ),
                at: 0
            )
        }
        snippets.sort { $0.updatedAt > $1.updatedAt }
        return nil
    }

    func deleteSnippet(_ snippet: TextSnippet) {
        snippets.removeAll { $0.id == snippet.id }
    }

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

    func dismissError() {
        if case .error = state { state = .idle }
    }

    var errorMessage: String? {
        guard case let .error(message) = state else { return nil }
        return message
    }

    var hasError: Bool { errorMessage != nil }

    func pasteLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        let snapshot = TextInsertionVerifier.capture()
        injector.beginSession(target: snapshot)
        injector.enqueue(lastTranscript)
    }

    func saveSettings() {
        if let data = try? JSONEncoder().encode(shortcut) { UserDefaults.standard.set(data, forKey: "shortcut") }
        UserDefaults.standard.set(barPlacement.rawValue, forKey: "barPlacement")
        UserDefaults.standard.set(barScale, forKey: "barScale")
        UserDefaults.standard.set(recognitionProfile.rawValue, forKey: "recognitionProfile")
        UserDefaults.standard.set(speechCleanupEnabled, forKey: "speechCleanupEnabled")
        UserDefaults.standard.set(typingBufferEnabled, forKey: "typingBufferEnabled")
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

    private var isError: Bool { hasError }

    private func prepareSpeechModel() async {
        let profile = recognitionProfile
        speechModelStatus = .preparing(progress: nil)
        do {
            try await transcriber.prepare(profile: profile) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard self?.recognitionProfile == profile,
                          self?.speechModelStatus != .ready else { return }
                    self?.speechModelStatus = .preparing(progress: progress)
                }
            }
            guard recognitionProfile == profile else { return }
            speechModelStatus = .ready
        } catch {
            guard recognitionProfile == profile else { return }
            speechModelStatus = .failed(error.localizedDescription)
        }
    }

    private func consume(_ update: LiveTranscriptUpdate) {
        guard isListening else { return }
        // The emitter formats against the dictionary snapshot captured when
        // dictation starts. Reformatting here could change text after the
        // emitter has already decided that it is safe to insert.
        liveText = update.transcript
        let insertion = update.insertion
        guard !insertion.isEmpty else { return }
        committedText += insertion
        injector.enqueue(insertion)
    }

    private func completeTranscription(_ rawText: String) {
        guard state == .finishing else { return }
        transcriptionTask = nil
        let finalText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
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
            liveText = finalText
        }
        state = .idle
        startedAt = nil
        audioLevel = 0

        let insertedText = committedText
        guard !insertedText.isEmpty else { return }
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

    private func failTranscription(_ error: Error) {
        guard isListening else { return }
        NSLog("Cadence stopped a live transcription: %@", String(describing: error))
        transcriptionTask = nil
        speechEngine.cancel()
        state = .error(error.localizedDescription)
        startedAt = nil
        audioLevel = 0
        insertionSnapshot = nil
    }

    private func persistDictionary() {
        UserDefaults.standard.set(dictionary, forKey: "customDictionary")
    }

    private func persistSnippets() {
        do {
            try snippetStore.save(snippets)
        } catch {
            NSLog("Cadence could not save snippets: %@", error.localizedDescription)
        }
    }

    private func persistRecords() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: "records") }
    }

    private static func loadRecords() -> [DictationRecord] {
        guard let data = UserDefaults.standard.data(forKey: "records"),
              let records = try? JSONDecoder().decode([DictationRecord].self, from: data) else { return [] }
        return records
    }

    private func loadSnippetsAndMigrateDefaults() -> [TextSnippet] {
        if FileManager.default.fileExists(atPath: snippetStore.fileURL.path) {
            do {
                return try snippetStore.load()
            } catch {
                NSLog("Cadence could not load snippets: %@", error.localizedDescription)
                return []
            }
        }
        guard let data = UserDefaults.standard.data(forKey: "textSnippets"),
              let legacy = try? JSONDecoder().decode([TextSnippet].self, from: data) else { return [] }
        let sorted = legacy.sorted { $0.updatedAt > $1.updatedAt }
        do {
            try snippetStore.save(sorted)
            UserDefaults.standard.removeObject(forKey: "textSnippets")
        } catch {
            NSLog("Cadence could not migrate snippets: %@", error.localizedDescription)
        }
        return sorted
    }
}

extension String {
    var wordCount: Int { split(whereSeparator: { $0.isWhitespace }).count }
}
