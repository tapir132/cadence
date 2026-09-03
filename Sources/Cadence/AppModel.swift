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
    var insertionVerification: InsertionVerificationResult?
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
    @Published private(set) var speechModelPreparationPhase: SpeechModelPreparationPhase = .loading
    @Published private(set) var isRequestingPermissions = false
    @Published private(set) var permissionRequestMessage: String?
    @Published private(set) var insertionRecovery: InsertionRecovery?
    @Published var selectedSection: SidebarSection = .home
    @Published var dictionary: [String] = [] { didSet { persistDictionary() } }
    @Published private(set) var snippets: [TextSnippet] = [] { didSet { persistSnippets() } }
    @Published var shortcut: ShortcutBinding = .standard {
        didSet {
            saveSettings()
            guard settingsAreLoaded else { return }
            GlobalHotKey.shared.binding = shortcut
        }
    }
    @Published var barPlacement: BarPlacement = .bottom { didSet { saveSettings() } }
    @Published var barScale = 0.85 { didSet { saveSettings() } }
    @Published var recognitionProfile: RecognitionProfile = .fast {
        didSet {
            saveSettings()
            guard settingsAreLoaded,
                  !isApplyingDictationProfile,
                  recognitionProfile != oldValue else { return }
            speechModelPreparationPhase = .loading
            speechModelStatus = .preparing(progress: nil)
            Task { [weak self] in await self?.prepareSpeechModel() }
        }
    }
    @Published var speechCleanupEnabled = false { didSet { saveSettings() } }
    @Published var deepEditingEnabled = false { didSet { saveSettings() } }
    @Published var typingBufferEnabled = false { didSet { saveSettings() } }
    @Published var characterPlaybackEnabled = false { didSet { saveSettings() } }
    @Published var characterPlaybackWordsPerMinute = CharacterPlaybackPacing.defaultWordsPerMinute {
        didSet { saveSettings() }
    }
    @Published var characterPlaybackRhythm: CharacterPlaybackRhythm = .steady {
        didSet { saveSettings() }
    }
    /// This stays independent from Quick, Normal, and Essay so changing a
    /// dictation profile never changes the listening environment.
    @Published var pauseMusicDuringDictation = false { didSet { saveSettings() } }
    @Published private(set) var freeBarX = 0.5
    @Published private(set) var freeBarY = 0.0

    private let speechEngine = AudioCaptureEngine()
    private let transcriber = LiveSpeechTranscriber()
    private let injector = KeystrokeInjector()
    private let mediaPlaybackController = MediaPlaybackController()
    private let snippetStore = TextSnippetStore()
    private var startedAt: Date?
    private var targetAppName = "Another app"
    private var insertionSnapshot: TextInsertionSnapshot?
    private var insertionVerificationTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var settingsAreLoaded = false
    private var isApplyingDictationProfile = false

    var isListening: Bool { state == .listening || state == .finishing }
    var lastTranscript: String { records.first?.text ?? "" }
    var totalWords: Int { records.reduce(0) { $0 + $1.text.wordCount } }
    var averageWPM: Int {
        let valid = records.filter { $0.wordsPerMinute > 0 }
        guard !valid.isEmpty else { return 0 }
        return valid.reduce(0) { $0 + $1.wordsPerMinute } / valid.count
    }
    var currentDuration: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    var dictationProfile: DictationProfile {
        DictationProfile.matching(currentDictationConfiguration)
    }

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
        let deliveryPreferences = TranscriptDeliveryPreferences.load(from: .standard)
        speechCleanupEnabled = deliveryPreferences.speechCleanupEnabled
        deepEditingEnabled = deliveryPreferences.deepEditingEnabled
        typingBufferEnabled = deliveryPreferences.typingBufferEnabled
        characterPlaybackEnabled = deliveryPreferences.characterPlaybackEnabled
        characterPlaybackWordsPerMinute = deliveryPreferences.characterPlaybackWordsPerMinute
        characterPlaybackRhythm = deliveryPreferences.characterPlaybackRhythm
        pauseMusicDuringDictation = UserDefaults.standard.bool(
            forKey: "pauseMusicDuringDictation"
        )
        freeBarX = UserDefaults.standard.object(forKey: "freeBarX") as? Double ?? 0.5
        freeBarY = UserDefaults.standard.object(forKey: "freeBarY") as? Double ?? 0
        if UserDefaults.standard.integer(forKey: "floatingBarDesignVersion") < 2 {
            barPlacement = .bottom
            barScale = 0.85
            freeBarY = 0
            UserDefaults.standard.set(2, forKey: "floatingBarDesignVersion")
        }
        settingsAreLoaded = true
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
                let action = speechModelPreparationPhase == .downloading
                    ? "downloading its Fast and Accurate models"
                    : "loading its downloaded speech model"
                state = .error("Cadence is \(action). Try again when Settings shows Ready.")
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
        injector.beginSession(
            target: insertionSnapshot,
            deliveryMode: textDeliveryMode
        )
        startedAt = Date()
        state = .listening

        mediaPlaybackController.begin(enabled: pauseMusicDuringDictation)
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
            mediaPlaybackController.end()
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
        mediaPlaybackController.end()
    }

    func cancelDictation() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        insertionVerificationTask?.cancel()
        insertionVerificationTask = nil
        speechEngine.cancel()
        injector.cancelPending()
        mediaPlaybackController.end()
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
        injector.beginSession(
            target: snapshot,
            deliveryMode: textDeliveryMode
        )
        injector.enqueue(lastTranscript)
    }

    func makeBugReport(
        updateChannel: UpdateChannel,
        automaticallyChecksForUpdates: Bool,
        automaticallyDownloadsUpdates: Bool,
        generatedAt: Date = Date()
    ) -> CadenceBugReport {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "Unversioned"

        let dictationStatus: String
        let dictationError: String?
        switch state {
        case .idle:
            dictationStatus = "idle"
            dictationError = nil
        case .listening:
            dictationStatus = "listening"
            dictationError = nil
        case .finishing:
            dictationStatus = "finishing"
            dictationError = nil
        case let .error(message):
            dictationStatus = "error"
            dictationError = message
        }

        let speechModelState: String
        let speechModelError: String?
        let speechModelProgress: Double?
        switch speechModelStatus {
        case let .preparing(progress):
            speechModelState = speechModelPreparationPhase.rawValue
            speechModelError = nil
            speechModelProgress = progress
        case .ready:
            speechModelState = "ready"
            speechModelError = nil
            speechModelProgress = nil
        case let .failed(message):
            speechModelState = "failed"
            speechModelError = message
            speechModelProgress = nil
        }

        return CadenceBugReport(
            reportFormatVersion: 1,
            generatedAt: generatedAt,
            privacy: CadenceBugReport.privacyNotice,
            application: .init(
                version: version,
                build: build,
                bundleIdentifier: bundle.bundleIdentifier ?? "app.cadence.mac"
            ),
            system: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: CadenceBugReport.currentArchitecture
            ),
            permissions: .init(
                microphone: microphoneAuthorized,
                accessibility: accessibilityAuthorized
            ),
            settings: .init(
                dictationProfile: dictationProfile.rawValue,
                recognitionProfile: recognitionProfile.rawValue,
                fillerWordCleanup: speechCleanupEnabled,
                deeperEditing: deepEditingEnabled,
                stabilityBuffer: typingBufferEnabled,
                characterPlayback: characterPlaybackEnabled,
                characterPlaybackWordsPerMinute: characterPlaybackWordsPerMinute,
                characterPlaybackRhythm: characterPlaybackRhythm.rawValue,
                pausesMusic: pauseMusicDuringDictation,
                shortcut: .init(
                    display: shortcut.displayText,
                    keyCode: shortcut.keyCode,
                    modifierFlags: shortcut.modifiersRawValue
                ),
                floatingBar: .init(
                    placement: barPlacement.rawValue,
                    scale: barScale,
                    freePositionX: freeBarX,
                    freePositionY: freeBarY
                ),
                updates: .init(
                    channel: updateChannel.rawValue,
                    checksAutomatically: automaticallyChecksForUpdates,
                    downloadsAutomatically: automaticallyDownloadsUpdates
                ),
                customDictionaryTermCount: dictionary.count,
                snippetCount: snippets.count
            ),
            status: .init(
                dictation: dictationStatus,
                dictationError: dictationError,
                speechModel: speechModelState,
                speechModelError: speechModelError,
                speechModelPreparationProgress: speechModelProgress,
                insertionRecoveryVisible: insertionRecovery != nil,
                insertionRecoveryTargetApplication: insertionRecovery?.appName
            ),
            recentDictations: records.prefix(CadenceBugReport.transcriptLimit).map { record in
                .init(
                    date: record.date,
                    text: record.text,
                    targetApplication: record.appName,
                    durationSeconds: record.duration,
                    wordsPerMinute: record.wordsPerMinute,
                    insertionVerification: record.insertionVerification?.rawValue
                )
            }
        )
    }

    func applyDictationProfile(_ profile: DictationProfile) {
        guard let configuration = profile.configuration else { return }
        let recognitionChanged = recognitionProfile != configuration.recognitionProfile
        let delivery = configuration.delivery

        isApplyingDictationProfile = true
        recognitionProfile = configuration.recognitionProfile
        speechCleanupEnabled = delivery.speechCleanupEnabled
        deepEditingEnabled = delivery.deepEditingEnabled
        typingBufferEnabled = delivery.typingBufferEnabled
        characterPlaybackEnabled = delivery.characterPlaybackEnabled
        characterPlaybackWordsPerMinute = delivery.characterPlaybackWordsPerMinute
        characterPlaybackRhythm = delivery.characterPlaybackRhythm
        isApplyingDictationProfile = false
        saveSettings()

        guard settingsAreLoaded, recognitionChanged else { return }
        speechModelPreparationPhase = .loading
        speechModelStatus = .preparing(progress: nil)
        Task { [weak self] in await self?.prepareSpeechModel() }
    }

    func saveSettings() {
        guard settingsAreLoaded, !isApplyingDictationProfile else { return }
        if let data = try? JSONEncoder().encode(shortcut) { UserDefaults.standard.set(data, forKey: "shortcut") }
        UserDefaults.standard.set(barPlacement.rawValue, forKey: "barPlacement")
        UserDefaults.standard.set(barScale, forKey: "barScale")
        UserDefaults.standard.set(recognitionProfile.rawValue, forKey: "recognitionProfile")
        UserDefaults.standard.set(
            pauseMusicDuringDictation,
            forKey: "pauseMusicDuringDictation"
        )
        TranscriptDeliveryPreferences(
            speechCleanupEnabled: speechCleanupEnabled,
            deepEditingEnabled: deepEditingEnabled,
            typingBufferEnabled: typingBufferEnabled,
            characterPlaybackEnabled: characterPlaybackEnabled,
            characterPlaybackWordsPerMinute: characterPlaybackWordsPerMinute,
            characterPlaybackRhythm: characterPlaybackRhythm
        ).save(to: .standard)
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

    private var currentDictationConfiguration: DictationConfiguration {
        DictationConfiguration(
            recognitionProfile: recognitionProfile,
            delivery: TranscriptDeliveryPreferences(
                speechCleanupEnabled: speechCleanupEnabled,
                deepEditingEnabled: deepEditingEnabled,
                typingBufferEnabled: typingBufferEnabled,
                characterPlaybackEnabled: characterPlaybackEnabled,
                characterPlaybackWordsPerMinute: characterPlaybackWordsPerMinute,
                characterPlaybackRhythm: characterPlaybackRhythm
            )
        )
    }

    private var textDeliveryMode: TextDeliveryMode {
        guard characterPlaybackEnabled else { return .chunked }
        return .characterByCharacter(
            CharacterPlaybackPacing(
                wordsPerMinute: characterPlaybackWordsPerMinute,
                rhythm: characterPlaybackRhythm
            )
        )
    }

    private func prepareSpeechModel() async {
        let profile = recognitionProfile
        speechModelPreparationPhase = .loading
        speechModelStatus = .preparing(progress: nil)
        do {
            try await transcriber.prepare(profile: profile) { [weak self] update in
                Task { @MainActor [weak self] in
                    guard self?.recognitionProfile == profile,
                          self?.speechModelStatus != .ready else { return }
                    self?.speechModelPreparationPhase = update.phase
                    self?.speechModelStatus = .preparing(progress: update.progress)
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
        let shouldDeepEdit = deepEditingEnabled
        insertionSnapshot = nil
        let duration = max(Date().timeIntervalSince(startedAt ?? Date()), 1)
        let insertedText = committedText
        guard !insertedText.isEmpty else {
            storeCompletedRecord(
                finalText,
                appName: completedTargetAppName,
                duration: duration
            )
            state = .idle
            startedAt = nil
            audioLevel = 0
            return
        }
        insertionVerificationTask?.cancel()
        insertionVerificationTask = Task { [weak self] in
            guard let self else { return }
            await injector.waitUntilDrained()
            guard !Task.isCancelled else { return }

            var deliveredText = finalText
            var verificationText = insertedText
            var recoveryText = finalText
            let editedText = DeepSpeechCleanupFormatter.format(
                finalText,
                enabled: shouldDeepEdit
            )
            if shouldDeepEdit,
               insertedText == finalText,
               editedText != finalText {
                switch await injector.replaceInsertedText(
                    insertedText,
                    with: editedText
                ) {
                case .applied:
                    deliveredText = editedText
                    verificationText = editedText
                    recoveryText = editedText
                case .skipped:
                    break
                case .failed:
                    recoveryText = editedText
                }
            }

            let recordID = storeCompletedRecord(
                deliveredText,
                appName: completedTargetAppName,
                duration: duration
            )
            committedText = deliveredText
            if state == .finishing {
                state = .idle
                startedAt = nil
                audioLevel = 0
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let result = TextInsertionVerifier.verify(
                snapshot,
                insertedText: verificationText,
                postingFailed: injector.hadPostingFailure
            )
            updateInsertionVerification(result, for: recordID)
            if result == .failed {
                insertionRecovery = InsertionRecovery(
                    text: recoveryText,
                    appName: completedTargetAppName
                )
            }
        }
    }

    @discardableResult
    private func storeCompletedRecord(
        _ text: String,
        appName: String,
        duration: TimeInterval
    ) -> UUID? {
        guard !text.isEmpty else { return nil }
        let record = DictationRecord(
            id: UUID(), date: Date(), text: text, appName: appName,
            duration: duration,
            wordsPerMinute: Int((Double(text.wordCount) / duration) * 60),
            insertionVerification: nil
        )
        records.insert(record, at: 0)
        records = Array(records.prefix(100))
        persistRecords()
        liveText = text
        return record.id
    }

    private func updateInsertionVerification(
        _ result: InsertionVerificationResult,
        for recordID: UUID?
    ) {
        guard let recordID,
              let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].insertionVerification = result
        persistRecords()
    }

    private func failTranscription(_ error: Error) {
        guard isListening else { return }
        NSLog("Cadence stopped a live transcription: %@", String(describing: error))
        transcriptionTask = nil
        speechEngine.cancel()
        mediaPlaybackController.end()
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
