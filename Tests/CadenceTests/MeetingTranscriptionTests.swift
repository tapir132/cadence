import FluidAudio
import Foundation
import Testing
@testable import Cadence

/// Real production ASR/VAD, with synthetic speech kept in temporary files.
/// Does not require a microphone, a call, or sending audio to a service.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CADENCE_RUN_MEETING_MODEL_TEST"] == "1"))
struct MeetingTranscriptionIntegrationTests {
    @Test(arguments: ProcessInfo.processInfo.environment["CADENCE_RUN_COHERE_MODEL_TEST"] == "1"
        ? MeetingRecognitionModel.allCases : [.parakeet])
    func independentChannelsPreserveQuietSpeechOverlapOrderAndFinalWords(model: MeetingRecognitionModel) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-meeting-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try speech("Can everyone see the dashboard?", named: "remote", in: directory)
        let local = try speech("I will send the document tomorrow.", named: "local", in: directory)
        let last = try speech("The final word is pineapple.", named: "last", in: directory)
        let silence = [Float](repeating: 0, count: 32_000)
        let transcriber = MeetingTranscriber()
        try await transcriber.prepare(model: model)
        let (microphone, mic) = AsyncStream<CapturedAudioChunk>.makeStream()
        let (system, sys) = AsyncStream<CapturedAudioChunk>.makeStream()
        let recorder = MeetingUpdateRecorder()
        let work = Task {
            try await transcriber.transcribe(MeetingAudioStreams(microphone: microphone, system: system)) {
                await recorder.apply($0)
            }
        }
        defer { work.cancel(); mic.finish(); sys.finish() }
        // Queue multiple remote turns before delivering the earlier mic turn.
        // Completion order is deliberately unrelated to capture order.
        feed(silence + remote + silence + remote + silence, to: sys, start: 100)
        sys.finish()
        // The other input has supplied no callbacks at all. Remote speech
        // must already be visible before any mic data or stop request arrives.
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while await recorder.note.lines.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await recorder.note.lines.count == 2)
        // A much quieter mic still owns all its words, including while the
        // remote speaker is talking. Finish without trailing silence to flush
        // the final partial VAD block and ASR right context.
        feed(silence + local.map { $0 * 0.15 } + silence + last, to: mic, start: 99)
        mic.finish()
        try await work.value
        let note = await recorder.note
        print("Meeting integration transcript:\n\(note.markdown)")
        let remoteLines = note.lines.filter { $0.speaker == .them }
        let localLines = note.lines.filter { $0.speaker == .you }
        #expect(remoteLines.count == 2)
        #expect(localLines.count == 2)
        #expect(remoteLines.allSatisfy { $0.text.lowercased().contains("dashboard") })
        #expect(localLines.first?.text.lowercased().contains("document tomorrow") == true)
        #expect(localLines.last?.text.lowercased().contains("pineapple") == true)
        #expect(note.lines.first?.speaker == .you)
        #expect(await recorder.updateCount > note.lines.count)
        if model == .cohere {
            #expect(await recorder.cohereUpdateCount == 4)
        } else {
            #expect(await recorder.cohereUpdateCount == 0)
        }
        #expect(note.lines.compactMap(\.startTime) == note.lines.compactMap(\.startTime).sorted())
        let store = MeetingNoteStore(fileURL: directory.appendingPathComponent("notes.json"))
        store.save([note])
        #expect(store.load().first?.markdown == note.markdown)

        // Reuse the warm models with a missing system input. No mixer backlog
        // may hold the mic's last words or invent a Them line.
        let (micOnly, micOnlyContinuation) = AsyncStream<CapturedAudioChunk>.makeStream()
        let (missingSystem, missingSystemContinuation) = AsyncStream<CapturedAudioChunk>.makeStream()
        missingSystemContinuation.finish()
        feed(silence + last, to: micOnlyContinuation, start: 200)
        micOnlyContinuation.finish()
        let micOnlyRecorder = MeetingUpdateRecorder()
        try await transcriber.transcribe(MeetingAudioStreams(microphone: micOnly, system: missingSystem)) {
            await micOnlyRecorder.apply($0)
        }
        let micOnlyNote = await micOnlyRecorder.note
        #expect(micOnlyNote.lines.count == 1)
        #expect(micOnlyNote.lines.first?.speaker == .you)
        #expect(micOnlyNote.lines.first?.text.lowercased().contains("pineapple") == true)
        if model == .cohere { #expect(await micOnlyRecorder.cohereUpdateCount == 1) }

        if model == .cohere {
            let longSpeech = try speech(
                "The weather looks clear for our walk through the park and we can bring a picnic with sandwiches and fruit while the children play near the trees and the rest of us talk about the books we have been reading and the places we would like to visit when the summer holidays begin and before we leave we should check the calendar and pack a bottle of water because the afternoon could be warm and the final word is pineapple.",
                named: "long", in: directory
            )
            #expect(longSpeech.count > MeetingChannelRecognizer.refinementSampleLimit)
            let (longMic, longContinuation) = AsyncStream<CapturedAudioChunk>.makeStream()
            feed(silence + longSpeech, to: longContinuation, start: 250)
            longContinuation.finish()
            let longRecorder = MeetingUpdateRecorder()
            try await transcriber.transcribe(MeetingAudioStreams(microphone: longMic, system: missingSystem)) {
                await longRecorder.apply($0)
            }
            let longNote = await longRecorder.note
            #expect(await longRecorder.cohereUpdateCount >= 2)
            #expect(longNote.lines.allSatisfy { $0.speaker == .you })
            #expect(longNote.lines.first?.text.lowercased().contains("weather") == true)
            #expect(longNote.lines.last?.text.lowercased().contains("pineapple") == true)
        }

        // Switching the prepared recognizer back must stop the second pass.
        try await transcriber.prepare(model: .parakeet)
        let (fallbackMic, fallbackContinuation) = AsyncStream<CapturedAudioChunk>.makeStream()
        feed(silence + last, to: fallbackContinuation, start: 300)
        fallbackContinuation.finish()
        let fallbackRecorder = MeetingUpdateRecorder()
        try await transcriber.transcribe(MeetingAudioStreams(microphone: fallbackMic, system: missingSystem)) {
            await fallbackRecorder.apply($0)
        }
        #expect(await fallbackRecorder.cohereUpdateCount == 0)
        #expect(await fallbackRecorder.note.lines.first?.text.lowercased().contains("pineapple") == true)
    }

    private func speech(_ text: String, named name: String, in directory: URL) throws -> [Float] {
        let url = directory.appendingPathComponent(name + ".aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", "175", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try AudioConverter().resampleAudioFile(url)
    }

    private func feed(
        _ samples: [Float],
        to continuation: AsyncStream<CapturedAudioChunk>.Continuation,
        start: TimeInterval
    ) {
        for offset in stride(from: 0, to: samples.count, by: 1_365) {
            let end = min(samples.count, offset + 1_365)
            continuation.yield(CapturedAudioChunk(
                samples: Array(samples[offset..<end]), startTime: start + Double(offset) / 16_000
            ))
        }
    }
}

private actor MeetingUpdateRecorder {
    private(set) var note = MeetingNote(id: UUID(), date: .now, title: "Test call", duration: 0, lines: [], thoughts: "")
    private(set) var updateCount = 0
    private(set) var cohereUpdateCount = 0

    func apply(_ update: MeetingTranscriptUpdate) {
        updateCount += 1
        if update.model == .cohere { cohereUpdateCount += 1 }
        note.apply(update)
    }
}
