import Foundation
import Testing
@testable import Cadence

/// Previously, delayed words used the current mixer energy and split a
/// remote sentence into Them/You. Now the originating turn owns every revision.
@Test func delayedRemoteWordsDoNotSwitchToTheMicrophoneSpeaker() {
    var note = MeetingNote(id: UUID(), date: .now, title: "Call", duration: 0, lines: [], thoughts: "")
    let remote = UUID()
    note.apply(MeetingTranscriptUpdate(id: remote, speaker: .them, startTime: 1, text: "Can everyone"))
    note.apply(MeetingTranscriptUpdate(id: UUID(), speaker: .you, startTime: 2, text: "Yes."))
    note.apply(MeetingTranscriptUpdate(id: remote, speaker: .them, startTime: 1, text: "Can everyone see the dashboard?"))
    #expect(note.lines.map(\.speaker) == [.them, .you])
    #expect(note.lines.map(\.text) == ["Can everyone see the dashboard?", "Yes."])
    #expect(note.markdown.contains("**Them:** Can everyone see the dashboard?"))
}

@Test func overlappingTurnsUseCaptureOrderAndKeepCorrectionsOnTheirOwnLine() {
    var note = MeetingNote(id: UUID(), date: .now, title: "Call", duration: 0, lines: [], thoughts: "")
    let you = UUID()
    let them = UUID()
    note.apply(MeetingTranscriptUpdate(id: you, speaker: .you, startTime: 3, text: "Yes."))
    // The earlier remote turn arrives after the reply's first hypothesis.
    note.apply(MeetingTranscriptUpdate(id: them, speaker: .them, startTime: 1, text: "Look at the bored"))
    note.apply(MeetingTranscriptUpdate(id: you, speaker: .you, startTime: 3, text: "Yes, I can."))
    note.apply(MeetingTranscriptUpdate(id: them, speaker: .them, startTime: 1, text: "Look at the board."))
    #expect(note.lines.map(\.id) == [them, you])
    #expect(note.lines.map(\.text) == ["Look at the board.", "Yes, I can."])
    note.apply(MeetingTranscriptUpdate(id: UUID(), speaker: .them, startTime: 8, text: " "))
    #expect(note.lines.count == 2)
    note.apply(MeetingTranscriptUpdate(id: them, speaker: .them, startTime: 1, text: ""))
    #expect(note.lines.map(\.id) == [you])
}

@Test func timestampedMeetingNotesRoundTripAndOldNotesStillLoad() throws {
    let oldJSON = #"{"id":"00000000-0000-0000-0000-000000000001","speaker":"you","text":"Old note."}"#
    let oldLine = try JSONDecoder().decode(MeetingLine.self, from: Data(oldJSON.utf8))
    #expect(oldLine.startTime == nil)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-note-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingNoteStore(fileURL: directory.appendingPathComponent("meetings.json"))
    var note = MeetingNote(id: UUID(), date: .now, title: "Call", duration: 10, lines: [], thoughts: "")
    note.apply(MeetingTranscriptUpdate(id: UUID(), speaker: .them, startTime: 1, text: "First sentence."))
    note.apply(MeetingTranscriptUpdate(id: UUID(), speaker: .you, startTime: 2, text: "My reply."))
    store.save([note])
    #expect(store.load() == [note])
    #expect(store.load().first?.markdown == note.markdown)
}

@Test func onlyKnownCallAppsInOtherProcessesCountAsACall() {
    let users = [
        MicrophoneUser(pid: 42, bundleIdentifier: "us.zoom.xos"),
        MicrophoneUser(pid: 7, bundleIdentifier: "com.electron.wispr-flow.helper"),
        MicrophoneUser(pid: 8, bundleIdentifier: nil),
        MicrophoneUser(pid: 99, bundleIdentifier: "com.google.Chrome.helper")
    ]
    #expect(MicrophoneUseMonitor.callCandidate(among: users, ownPID: 42)?.pid == 99)
    #expect(MicrophoneUseMonitor.callCandidate(among: Array(users[1...2]), ownPID: 1) == nil)
    #expect(MicrophoneUseMonitor.appName(for: users[3]) == "Chrome")
    #expect(MicrophoneUseMonitor.appName(for: MicrophoneUser(pid: 5, bundleIdentifier: "com.microsoft.teams2")) == "Teams")
}

@MainActor
@Test func detectionCardAppearsOnceAndSnoozesUntilTheCallEnds() {
    let store = MeetingNoteStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("cadence-\(UUID()).json"))
    let model = MeetingNotesModel(store: store, polls: false)
    let zoom = [MicrophoneUser(pid: 99, bundleIdentifier: "us.zoom.xos")]
    model.poll(users: zoom)
    #expect(model.detectedCall != nil)
    model.dismissDetectedCall()
    model.poll(users: zoom)
    #expect(model.detectedCall == nil)
    model.poll(users: [])
    model.poll(users: zoom)
    #expect(model.detectedCall != nil)
}
