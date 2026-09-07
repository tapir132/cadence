@preconcurrency import AppKit
import Foundation

struct MeetingLine: Identifiable, Codable, Equatable {
    var id = UUID()
    var speaker: MeetingSpeaker
    var text: String
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

    /// Appends the decoder's next append-only word delta to the transcript,
    /// starting a new line whenever the louder side of the call changes.
    mutating func append(_ insertion: String, deleteBackward: Int, speaker: MeetingSpeaker) {
        if deleteBackward > 0, let last = lines.indices.last {
            lines[last].text = String(lines[last].text.dropLast(deleteBackward))
        }
        // Deltas carry their own spacing ("Can everyone ", "see"), so keep the
        // text raw and only drop the leading space of a brand-new line.
        guard insertion.contains(where: { !$0.isWhitespace }) else { return }
        if let last = lines.indices.last, lines[last].speaker == speaker {
            lines[last].text += insertion
        } else {
            lines.append(MeetingLine(speaker: speaker, text: String(insertion.drop(while: \.isWhitespace))))
        }
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
    case finished
}

struct MeetingSession: Equatable {
    let noteID: UUID
    let startedAt: Date
    let startedFromCall: Bool
    var phase: MeetingSessionPhase
    var systemAudioUnavailable = false
    var error: String?
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
    @Published var isNotepadVisible = false
    @Published var offersNotesForCalls: Bool {
        didSet { UserDefaults.standard.set(offersNotesForCalls, forKey: "offersNotesForCalls") }
    }
    /// The one-line result of the last system-audio attempt. macOS has no
    /// public API to query this grant, so the last real capture is the evidence.
    @Published private(set) var systemAudioStatus: String?

    private let store: MeetingNoteStore
    private let transcriber = LiveSpeechTranscriber()
    private var source: MeetingAudioSource?
    private var transcriptionTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var snoozedCall = false
    private var quietCallPolls = 0

    var isRecording: Bool { session?.phase == .recording || session?.phase == .preparing }
    var currentNote: MeetingNote? { session.flatMap { session in notes.first { $0.id == session.noteID } } }

    init(store: MeetingNoteStore = MeetingNoteStore(), polls: Bool = true) {
        self.store = store
        notes = store.load()
        offersNotesForCalls = UserDefaults.standard.object(forKey: "offersNotesForCalls") as? Bool ?? true
        guard polls else { return }
        // ponytail: a 2 s poll of Core Audio's process list; property listeners
        // if the poll ever shows up in Activity Monitor.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
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
        quietCallPolls = 0
        isNotepadVisible = true
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in await self?.record(noteID: note.id) }
    }

    func stopRecording() {
        guard let session, session.phase == .recording else { return }
        source?.finish()
        audioLevel = 0
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
        var microphoneAllowed = AudioCaptureEngine.microphoneAuthorized
        if !microphoneAllowed { microphoneAllowed = await AudioCaptureEngine.requestPermissions() }
        guard microphoneAllowed else {
            fail("Microphone access is required.", noteID: noteID)
            return
        }
        do {
            try await transcriber.prepare(profile: .fast) { _ in }
        } catch {
            fail("The local speech model could not load: \(error.localizedDescription)", noteID: noteID)
            return
        }
        guard session?.noteID == noteID else { return }

        let source = MeetingAudioSource()
        let audio: AsyncStream<[Float]>
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
        self.source = source
        session?.phase = .recording
        if let error = source.systemAudioError {
            session?.systemAudioUnavailable = true
            systemAudioStatus = error.localizedDescription
        } else {
            systemAudioStatus = "Capturing the other side of calls."
        }

        // The emitter stops when the model rewrites already-shown words, which
        // protects a document during dictation. A transcript just keeps going.
        var finished = false
        while !finished, !Task.isCancelled {
            do {
                _ = try await transcriber.transcribe(audio) { [weak self, weak source] update in
                    guard let source else { return }
                    let speaker = source.dominantSpeaker
                    await self?.apply(update, speaker: speaker, to: noteID)
                }
                finished = true
            } catch let error as LiveTranscriptError {
                NSLog("Cadence Notes restarted transcription: %@", String(describing: error))
                appendBreak(to: noteID)
            } catch is SpeechEngineError {
                finished = true
            } catch {
                fail(error.localizedDescription, noteID: noteID)
                return
            }
        }
        finish(noteID: noteID)
    }

    private func apply(_ update: LiveTranscriptUpdate, speaker: MeetingSpeaker, to noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[index].append(update.insertion, deleteBackward: update.deleteBackward, speaker: speaker)
    }

    /// A restarted decoder cannot continue the previous line's spelling, so
    /// force the next words onto a fresh line.
    private func appendBreak(to noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }),
              let last = notes[index].lines.indices.last else { return }
        notes[index].lines[last].text = notes[index].lines[last].text.trimmingCharacters(in: .whitespaces)
        if !notes[index].lines[last].text.hasSuffix(".") { notes[index].lines[last].text += " …" }
    }

    private func finish(noteID: UUID) {
        source = nil
        transcriptionTask = nil
        audioLevel = 0
        if let index = notes.firstIndex(where: { $0.id == noteID }), let session {
            notes[index].duration = Date().timeIntervalSince(session.startedAt)
        }
        if session?.noteID == noteID { session?.phase = .finished }
        store.save(notes)
    }

    private func fail(_ message: String, noteID: UUID) {
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
