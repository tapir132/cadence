@preconcurrency import AppKit
import Foundation

struct MeetingLine: Identifiable, Codable, Equatable {
    var id = UUID()
    var speaker: MeetingSpeaker
    var text: String
    var startTime: TimeInterval? = nil
}

struct MeetingNote: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    var title: String
    var duration: TimeInterval
    var lines: [MeetingLine]
    var thoughts: String


    var markdown: String {
        var text = "# \(title)\n\n\(date.formatted(date: .abbreviated, time: .shortened)) · \(Self.durationText(duration))\n"
        let thoughts = thoughts.trimmingCharacters(in: .whitespacesAndNewlines)
        if !thoughts.isEmpty { text += "\n## My thoughts\n\n\(thoughts)\n" }
        if !lines.isEmpty {
            text += "\n## Transcript\n\n"
            text += lines.map { "**\($0.speaker.title):** \($0.text.trimmingCharacters(in: .whitespaces))" }
                .joined(separator: "\n\n") + "\n"
        }
        return text
    }

    static func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return total >= 3_600
            ? String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Apply a complete hypothesis to its original turn, preserving source
    /// identity and capture order when the two recognizers finish out of order.
    mutating func apply(_ update: MeetingTranscriptUpdate) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = lines.firstIndex(where: { $0.id == update.id }) {
            if text.isEmpty { lines.remove(at: index) } else { lines[index].text = text }
            return
        }
        guard !text.isEmpty else { return }
        let line = MeetingLine(id: update.id, speaker: update.speaker, text: text, startTime: update.startTime)
        let index = lines.firstIndex { ($0.startTime ?? -.infinity) > update.startTime } ?? lines.endIndex
        lines.insert(line, at: index)
    }
}

struct MeetingNoteStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? TextSnippetStore().fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("meetings.json")
    }

    func load() -> [MeetingNote] {
        guard let data = try? Data(contentsOf: fileURL),
              let notes = try? JSONDecoder().decode([MeetingNote].self, from: data) else { return [] }
        return notes.sorted { $0.date > $1.date }
    }

    func save(_ notes: [MeetingNote]) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try JSONEncoder().encode(notes).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Cadence could not save meeting notes: %@", error.localizedDescription)
        }
    }
}

struct DetectedCall: Equatable {
    let appName: String
}

enum MeetingSessionPhase: Equatable {
    case preparing
    case recording
    case finishing
    case finished
}

struct MeetingSession: Equatable {
    let noteID: UUID
    var startedAt: Date
    let startedFromCall: Bool
    var phase: MeetingSessionPhase
    var systemAudioUnavailable = false
    var error: String?
    var model: MeetingRecognitionModel = .parakeet
    var modelWarning: String?
}

/// The live note taker: notices when another app opens the microphone, offers
/// to take notes, and transcribes both sides of the call locally.
@MainActor
final class MeetingNotesModel: ObservableObject {
    static let shared = MeetingNotesModel()

    @Published private(set) var detectedCall: DetectedCall?
    @Published private(set) var session: MeetingSession?
    @Published private(set) var notes: [MeetingNote]
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var recognitionModel: MeetingRecognitionModel
    @Published private(set) var preparationUpdate: SpeechModelPreparationUpdate?
    @Published private(set) var modelSetup = MeetingModelSetup()
    @Published var isNotepadVisible = false
    @Published var offersNotesForCalls: Bool {
        didSet { UserDefaults.standard.set(offersNotesForCalls, forKey: "offersNotesForCalls") }
    }
    /// The one-line result of the last system-audio attempt. macOS has no
    /// public API to query this grant, so the last real capture is the evidence.
    @Published private(set) var systemAudioStatus: String?

    private let store: MeetingNoteStore
    private let defaults: UserDefaults
    private let transcriber: MeetingTranscriber
    private let modelPreparation: MeetingModelPreparation
    private var hasStartedSetup = false
    private var source: MeetingAudioSource?
    private var transcriptionTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var snoozedCall = false
    private var quietCallPolls = 0

    var isRecording: Bool { session != nil && session?.phase != .finished }
    var currentNote: MeetingNote? { session.flatMap { session in notes.first { $0.id == session.noteID } } }

    var preparationDescription: String {
        guard let preparationUpdate else { return "Preparing local transcription…" }
        switch preparationUpdate.phase {
        case .loading: return "Loading local speech models…"
        case .downloading:
            if let progress = preparationUpdate.progress {
                return "Downloading speech models · \(Int(progress * 100))%"
            }
            return "Downloading speech models…"
        }
    }

    init(store: MeetingNoteStore = MeetingNoteStore(), polls: Bool = true, defaults: UserDefaults = .standard) {
        let transcriber = MeetingTranscriber()
        self.transcriber = transcriber
        modelPreparation = MeetingModelPreparation(
            prepareLive: { progress in try await transcriber.prepareLive(onProgress: progress) },
            prepareCohere: { progress in try await transcriber.prepareCohere(onProgress: progress) }
        )
        self.store = store
        self.defaults = defaults
        notes = store.load()
        recognitionModel = MeetingRecognitionModel.load(from: defaults)
        offersNotesForCalls = UserDefaults.standard.object(forKey: "offersNotesForCalls") as? Bool ?? true
        guard polls else { return }
        // ponytail: a 2 s poll of Core Audio's process list; property listeners
        // if the poll ever shows up in Activity Monitor.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func selectRecognitionModel(_ model: MeetingRecognitionModel) {
        guard !isRecording, model.isSupported else { return }
        recognitionModel = model
        defaults.set(model.rawValue, forKey: MeetingRecognitionModel.preferenceKey)
        if hasStartedSetup { prepareForMeetings() }
    }

    /// Called after the app's initial dictation download finishes, avoiding
    /// concurrent installers writing the shared Parakeet model files.
    func prepareForMeetings() {
        hasStartedSetup = true
        modelPreparation.onChange = { [weak self] setup in
            self?.modelSetup = setup
            if case let .preparing(update) = setup.live { self?.preparationUpdate = update }
        }
        modelPreparation.start(for: recognitionModel)
    }

    func poll(users: [MicrophoneUser]? = nil) {
        let call = MicrophoneUseMonitor.callCandidate(among: users ?? MicrophoneUseMonitor.processesUsingMicrophone())
        if let session, session.phase == .recording, session.startedFromCall {
            detectedCall = nil
            // Zoom and Teams briefly reopen the microphone between states, so
            // wait for three quiet polls before deciding the call has ended.
            quietCallPolls = call == nil ? quietCallPolls + 1 : 0
            if quietCallPolls >= 3 { stopRecording() }
            return
        }
        guard let call else {
            detectedCall = nil
            snoozedCall = false
            return
        }
        guard !isRecording, offersNotesForCalls, !snoozedCall else { return }
        let name = MicrophoneUseMonitor.appName(for: call)
        if detectedCall?.appName != name { detectedCall = DetectedCall(appName: name) }
    }

    func dismissDetectedCall() {
        snoozedCall = true
        detectedCall = nil
    }

    func startRecordingDetectedCall() {
        let appName = detectedCall?.appName ?? "Call"
        detectedCall = nil
        snoozedCall = true
        startRecording(title: "\(appName) call", fromCall: true)
    }

    func startRecording(title: String = "Meeting", fromCall: Bool = false) {
        guard !isRecording else { return }
        let note = MeetingNote(id: UUID(), date: Date(), title: title, duration: 0, lines: [], thoughts: "")
        notes.insert(note, at: 0)
        session = MeetingSession(noteID: note.id, startedAt: note.date, startedFromCall: fromCall, phase: .preparing)
        session?.model = recognitionModel
        preparationUpdate = nil
        quietCallPolls = 0
        isNotepadVisible = true
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in await self?.record(noteID: note.id) }
    }

    func stopRecording() {
        guard let session else { return }
        switch session.phase {
        case .preparing:
            transcriptionTask?.cancel()
            // Model setup belongs to the app and keeps running for the next
            // call. Cancelling a pending note must not throw away that work.
            finish(noteID: session.noteID)
        case .recording:
            source?.finish()
            markFinishing(noteID: session.noteID)
        case .finishing, .finished:
            break
        }
    }

    func updateThoughts(_ text: String, for noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }), notes[index].thoughts != text else { return }
        notes[index].thoughts = text
        store.save(notes)
    }

    func delete(_ note: MeetingNote) {
        notes.removeAll { $0.id == note.id }
        if session?.noteID == note.id { session = nil }
        store.save(notes)
    }

    func copyMarkdown(_ note: MeetingNote) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.markdown, forType: .string)
    }

    private func record(noteID: UUID) async {
        guard let activeSession = session, activeSession.noteID == noteID else { return }
        let transcriber = transcriber
        var microphoneAllowed = AudioCaptureEngine.microphoneAuthorized
        if !microphoneAllowed { microphoneAllowed = await AudioCaptureEngine.requestPermissions() }
        guard !Task.isCancelled else { return }
        guard microphoneAllowed else {
            fail("Microphone access is required.", noteID: noteID)
            return
        }
        do {
            prepareForMeetings()
            try await modelPreparation.ensureLiveReady()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, session?.noteID == noteID else { return }
            fail("The local speech model could not load: \(error.localizedDescription)", noteID: noteID)
            return
        }
        guard !Task.isCancelled, session?.noteID == noteID else { return }
        let recordingModel = modelSetup.recordingModel(preferred: activeSession.model)
        session?.model = recordingModel
        if recordingModel != activeSession.model {
            if case .failed = modelSetup.cohere {
                session?.modelWarning = "This recording uses Parakeet because Cohere couldn't prepare. You can retry setup after the recording."
            } else {
                session?.modelWarning = "This recording uses Parakeet while Cohere finishes setup. You can keep taking notes."
            }
        }

        let source = MeetingAudioSource()
        let audio: MeetingAudioStreams
        do {
            // The first tap creation blocks inside macOS's System Audio prompt
            // until the person answers it; keep the notepad responsive meanwhile.
            audio = try await Task.detached(priority: .userInitiated) {
                try source.start { [weak self] level in
                    Task { @MainActor in self?.audioLevel = level }
                }
            }.value
        } catch {
            fail(error.localizedDescription, noteID: noteID)
            return
        }
        guard !Task.isCancelled, session?.noteID == noteID else {
            source.finish()
            return
        }
        self.source = source
        session?.startedAt = .now
        session?.phase = .recording
        preparationUpdate = nil
        if let error = source.systemAudioError {
            session?.systemAudioUnavailable = true
            systemAudioStatus = error.localizedDescription
        } else {
            systemAudioStatus = "Capturing the other side of calls."
        }

        do {
            try await transcriber.transcribe(audio, model: recordingModel, onFinishing: { [weak self] in
                await self?.markFinishing(noteID: noteID)
            }, onFallback: { [weak self] in
                await self?.markModelFallback(noteID: noteID)
            }) { [weak self] update in
                await self?.apply(update, to: noteID)
            }
        } catch is CancellationError {
            source.finish()
            return
        } catch {
            fail(error.localizedDescription, noteID: noteID)
            return
        }
        finish(noteID: noteID)
    }

    private func markFinishing(noteID: UUID) {
        guard session?.noteID == noteID, session?.phase == .recording else { return }
        if let index = notes.firstIndex(where: { $0.id == noteID }), let session {
            notes[index].duration = Date().timeIntervalSince(session.startedAt)
        }
        session?.phase = .finishing
        audioLevel = 0
    }

    private func markModelFallback(noteID: UUID) {
        guard session?.noteID == noteID else { return }
        session?.modelWarning = "Some phrases kept their Parakeet transcript because Cohere could not finish them."
    }

    private func apply(_ update: MeetingTranscriptUpdate, to noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[index].apply(update)
    }

    private func finish(noteID: UUID) {
        guard session?.noteID == noteID else { return }
        source = nil
        transcriptionTask = nil
        audioLevel = 0
        if let index = notes.firstIndex(where: { $0.id == noteID }), let session, session.phase == .recording {
            notes[index].duration = Date().timeIntervalSince(session.startedAt)
        }
        if session?.noteID == noteID { session?.phase = .finished }
        store.save(notes)
    }

    private func fail(_ message: String, noteID: UUID) {
        guard session?.noteID == noteID else { return }
        source?.finish()
        source = nil
        transcriptionTask = nil
        audioLevel = 0
        if session?.noteID == noteID {
            session?.phase = .finished
            session?.error = message
        }
        // Nothing was captured; do not keep an empty note around.
        if let index = notes.firstIndex(where: { $0.id == noteID }), notes[index].lines.isEmpty, notes[index].thoughts.isEmpty {
            notes.remove(at: index)
        }
        store.save(notes)
    }
}
