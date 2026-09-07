import Foundation
import Testing
@testable import Cadence

@Test func mixerSumsAlignedFramesAndTracksTheLouderSide() {
    var mixer = MeetingAudioMixer()
    let frame = MeetingAudioMixer.frameSize
    #expect(mixer.push(.you, [Float](repeating: 0.1, count: frame)).isEmpty)
    let mixed = mixer.push(.them, [Float](repeating: 0.5, count: frame))
    #expect(mixed.count == 1)
    #expect(mixed[0].count == frame)
    #expect(abs(mixed[0][0] - 0.6) < 0.0001)
    #expect(mixer.dominantSpeaker == .them)

    _ = mixer.push(.them, [Float](repeating: 0, count: frame * 3))
    for _ in 0..<3 { _ = mixer.push(.you, [Float](repeating: 0.4, count: frame)) }
    #expect(mixer.dominantSpeaker == .you)
}

@Test func mixerReleasesOneSideWhenTheOtherIsSilentForTooLong() {
    var mixer = MeetingAudioMixer()
    let frame = MeetingAudioMixer.frameSize
    var frames: [[Float]] = []
    for _ in 0..<7 { frames += mixer.push(.you, [Float](repeating: 0.2, count: frame)) }
    #expect(frames.isEmpty)
    frames += mixer.push(.you, [Float](repeating: 0.2, count: frame))
    #expect(frames.count == 1)
    #expect(frames[0].allSatisfy { abs($0 - 0.2) < 0.0001 })
    #expect(mixer.dominantSpeaker == .you)
}

@Test func noteGroupsConsecutiveWordsBySpeakerAndRetractsPeriods() {
    var note = MeetingNote(id: UUID(), date: .now, title: "Zoom call", duration: 0, lines: [], thoughts: "")
    note.append("Can everyone ", deleteBackward: 0, speaker: .them)
    note.append("see the dashboard?", deleteBackward: 0, speaker: .them)
    note.append("Yes.", deleteBackward: 0, speaker: .you)
    note.append(" I can", deleteBackward: 1, speaker: .you)
    #expect(note.lines.map(\.text) == ["Can everyone see the dashboard?", "Yes I can"])
    note.append(" ", deleteBackward: 0, speaker: .them)
    #expect(note.lines.count == 2)
    #expect(note.lines.map(\.speaker) == [.them, .you])
    #expect(note.markdown.contains("**Them:** Can everyone see the dashboard?"))
    #expect(note.markdown.contains("**You:** Yes I can"))
}

@Test func onlyOtherProcessesCountAsACall() {
    let users = [MicrophoneUser(pid: 42, bundleIdentifier: "app.cadence.mac"), MicrophoneUser(pid: 99, bundleIdentifier: "us.zoom.xos")]
    #expect(MicrophoneUseMonitor.callCandidate(among: users, ownPID: 42)?.pid == 99)
    #expect(MicrophoneUseMonitor.callCandidate(among: [users[0]], ownPID: 42) == nil)
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
