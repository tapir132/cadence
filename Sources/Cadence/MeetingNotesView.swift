@preconcurrency import AppKit
@preconcurrency import Combine
import SwiftUI

/// "Meeting detected" card, shown beside the floating bar when another app
/// opens the microphone. One tap starts notes; the X snoozes until the call ends.
struct MeetingDetectedCard: View {
    @EnvironmentObject private var meetings: MeetingNotesModel

    var body: some View {
        if let call = meetings.detectedCall {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    BrandMark(size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meeting detected")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text("\(call.appName) is using your microphone. Cadence can take notes on this Mac; nothing joins the call.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { meetings.dismissDetectedCall() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .accessibilityLabel("Dismiss meeting detection")
                }
                HStack {
                    Text("Transcript and notes stay on this Mac.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Spacer()
                    Button { meetings.startRecordingDetectedCall() } label: {
                        Label("Take notes", systemImage: "record.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CadenceTheme.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Capsule().fill(CadenceTheme.lime))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(width: 390)
            .foregroundStyle(CadenceTheme.cream)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(CadenceTheme.ink.opacity(0.98))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12)))
            )
        }
    }
}

/// Hosts a card in a non-activating panel beside the floating bar.
@MainActor
final class OverlayCardController {
    private let panel: NSPanel

    init<Content: View>(size: NSSize, content: Content) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: content)
    }

    func show(near floatingFrame: NSRect, in visible: NSRect) {
        let size = panel.frame.size
        let preferredBelow = floatingFrame.minY - size.height - 10
        let preferredAbove = floatingFrame.maxY + 10
        let y = preferredBelow >= visible.minY ? preferredBelow : min(preferredAbove, visible.maxY - size.height)
        let origin = SnapGeometry.clamped(
            NSPoint(x: floatingFrame.midX - size.width / 2, y: y),
            size: size,
            in: visible.insetBy(dx: 8, dy: 8)
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private enum NotepadTab: String, CaseIterable {
    case transcript = "Transcript"
    case thoughts = "My thoughts"
}

/// The note itself: a header with the recording pill, then Transcript and My
/// thoughts tabs. Used live in the floating notepad and for saved notes in Hub.
struct MeetingNoteView: View {
    @EnvironmentObject private var meetings: MeetingNotesModel
    let note: MeetingNote
    var compact = false
    @State private var tab: NotepadTab = .transcript
    @State private var thoughts = ""
    @State private var copied = false

    private var live: MeetingSession? {
        meetings.session?.noteID == note.id ? meetings.session : nil
    }
    private var isRecording: Bool { live?.phase == .recording || live?.phase == .preparing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs
            Rectangle().fill(CadenceTheme.line).frame(height: 1)
            if let error = live?.error {
                Text(error)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(CadenceTheme.coral)
                    .padding(.horizontal, compact ? 18 : 0).padding(.top, 12)
            }
            if live?.systemAudioUnavailable == true {
                Text("Only your voice is being captured. Allow Cadence under System Settings → Privacy & Security → Screen & System Audio Recording to hear the other side.")
                    .font(.system(size: 11)).foregroundStyle(CadenceTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, compact ? 18 : 0).padding(.top, 12)
            }
            switch tab {
            case .transcript: transcript
            case .thoughts: thoughtsEditor
            }
        }
        .onAppear {
            thoughts = note.thoughts
            if isRecording, note.lines.isEmpty, !note.thoughts.isEmpty { tab = .thoughts }
        }
        .onChange(of: thoughts) { _, value in meetings.updateThoughts(value, for: note.id) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.system(size: compact ? 22 : 30, weight: .medium, design: .serif))
                    .tracking(-0.8)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if isRecording {
                        Circle().fill(CadenceTheme.coral).frame(width: 7, height: 7)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(MeetingNote.durationText(context.date.timeIntervalSince(live?.startedAt ?? note.date)))
                        }
                        Text(live?.phase == .preparing ? "· Loading local model…" : "· Recording")
                    } else {
                        Text(note.date.formatted(date: .abbreviated, time: .shortened))
                        Text("· \(MeetingNote.durationText(note.duration))")
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CadenceTheme.muted)
            }
            Spacer()
            if isRecording {
                recordingPill
            } else {
                Button {
                    meetings.copyMarkdown(note)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy as Markdown", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, compact ? 18 : 0)
        .padding(.top, compact ? 16 : 0)
        .padding(.bottom, 14)
    }

    /// Dark pill with the live waveform and a stop square, as on the call itself.
    private var recordingPill: some View {
        Button { meetings.stopRecording() } label: {
            HStack(spacing: 10) {
                WaveformMark(level: meetings.audioLevel, color: CadenceTheme.lime, bars: 5)
                    .frame(width: 26)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(CadenceTheme.cream)
                    .frame(width: 12, height: 12)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(CadenceTheme.ink))
        }
        .buttonStyle(.plain)
        .help("Stop taking notes")
        .accessibilityLabel("Stop taking notes")
        .disabled(live?.phase != .recording)
    }

    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(NotepadTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            if item == .transcript, isRecording {
                                WaveformMark(level: meetings.audioLevel, color: CadenceTheme.coral, bars: 3)
                                    .frame(width: 12, height: 10)
                            }
                            Text(item.rawValue)
                                .font(.system(size: 13, weight: tab == item ? .semibold : .medium))
                        }
                        .foregroundStyle(tab == item ? CadenceTheme.ink : CadenceTheme.muted)
                        Rectangle().fill(tab == item ? CadenceTheme.ink : .clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, compact ? 18 : 0)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if note.lines.isEmpty {
                        Text(isRecording ? "Listening. Words appear here as people speak." : "Nothing was said while notes were on.")
                            .font(.system(size: 14)).foregroundStyle(CadenceTheme.muted)
                            .padding(.top, 8)
                    }
                    ForEach(note.lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.speaker.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(CadenceTheme.muted)
                            Text(line.text)
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(line.speaker == .you ? CadenceTheme.lime.opacity(0.28) : CadenceTheme.paperDeep.opacity(0.7))
                                )
                        }
                        .frame(maxWidth: .infinity, alignment: line.speaker == .you ? .trailing : .leading)
                        .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, compact ? 18 : 0)
                .padding(.vertical, 14)
            }
            .onChange(of: note.lines.last?.text) { _, _ in
                guard isRecording else { return }
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }

    private var thoughtsEditor: some View {
        TextEditor(text: $thoughts)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .padding(compact ? 12 : 8)
            .overlay(alignment: .topLeading) {
                if thoughts.isEmpty {
                    Text("Type or dictate your own notes here while the call runs.")
                        .font(.system(size: 14)).foregroundStyle(CadenceTheme.muted.opacity(0.7))
                        .padding(.horizontal, compact ? 17 : 13).padding(.top, compact ? 20 : 16)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The standalone floating notepad that opens when notes start.
@MainActor
final class MeetingNotepadWindowController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let meetings: MeetingNotesModel
    private var cancellables = Set<AnyCancellable>()

    init(meetings: MeetingNotesModel) {
        self.meetings = meetings
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Notes"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 340, height: 320)
        panel.backgroundColor = NSColor(CadenceTheme.paper)
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("CadenceNotepad")
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: MeetingNotepadView().environmentObject(meetings))

        meetings.$isNotepadVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                guard let self else { return }
                if visible {
                    if !panel.isVisible, panel.frameAutosaveName.isEmpty || !panel.setFrameUsingName("CadenceNotepad") {
                        positionBesideMenuBar()
                    }
                    panel.makeKeyAndOrderFront(nil)
                } else {
                    panel.orderOut(nil)
                }
            }
            .store(in: &cancellables)
    }

    private func positionBesideMenuBar() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 16, y: visible.maxY - panel.frame.height - 16))
    }

    func windowWillClose(_ notification: Notification) {
        meetings.isNotepadVisible = false
    }
}

private struct MeetingNotepadView: View {
    @EnvironmentObject private var meetings: MeetingNotesModel

    var body: some View {
        ZStack {
            CadenceTheme.paper.ignoresSafeArea()
            if let note = meetings.currentNote {
                MeetingNoteView(note: note, compact: true)
                    .id(note.id)
            } else {
                Text("No notes are being taken.")
                    .font(.system(size: 12)).foregroundStyle(CadenceTheme.muted)
            }
        }
        .frame(minWidth: 340, minHeight: 320)
        .preferredColorScheme(.light)
    }
}

/// Hub section: past meetings and a manual start for in-person conversations.
struct NotesView: View {
    @EnvironmentObject private var meetings: MeetingNotesModel
    @State private var selectedID: UUID?

    private var selected: MeetingNote? {
        meetings.notes.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 400)
            Rectangle().fill(CadenceTheme.line).frame(width: 1)
            detail
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NOTES")
                .font(.system(size: 10, weight: .bold)).tracking(1.8)
                .foregroundStyle(CadenceTheme.muted)
                .padding(.top, 20)
            Text("Every call, in your words.")
                .font(.system(size: 40, weight: .medium, design: .serif))
                .tracking(-1.4)
                .padding(.top, 28)
            Text("When a call app opens your microphone, Cadence offers to take notes. Both sides are transcribed on this Mac; nothing joins the call.")
                .font(.system(size: 14)).foregroundStyle(CadenceTheme.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Button {
                if meetings.isRecording {
                    meetings.isNotepadVisible = true
                } else {
                    meetings.startRecording()
                }
            } label: {
                Label(meetings.isRecording ? "Open live notes" : "Take notes now", systemImage: meetings.isRecording ? "record.circle.fill" : "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(meetings.isRecording ? CadenceTheme.coral : CadenceTheme.ink)
            .controlSize(.large)
            .padding(.top, 22)

            if meetings.notes.isEmpty {
                Text("Your first meeting will land here.")
                    .font(.system(size: 14)).foregroundStyle(CadenceTheme.muted)
                    .padding(.top, 36)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(meetings.notes) { note in
                            row(note)
                            Rectangle().fill(CadenceTheme.line).frame(height: 1)
                        }
                    }
                }
                .padding(.top, 32)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
    }

    private func row(_ note: MeetingNote) -> some View {
        Button { selectedID = note.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(note.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if meetings.session?.noteID == note.id, meetings.isRecording {
                        Circle().fill(CadenceTheme.coral).frame(width: 7, height: 7)
                    }
                }
                Text(note.lines.first?.text ?? (note.thoughts.isEmpty ? "No transcript" : note.thoughts))
                    .font(.system(size: 13)).foregroundStyle(CadenceTheme.muted).lineLimit(2).lineSpacing(2)
                Text("\(note.date.formatted(date: .abbreviated, time: .shortened)) · \(MeetingNote.durationText(note.duration))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(CadenceTheme.muted)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selectedID == note.id ? Color.white.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var detail: some View {
        Group {
            if let note = selected {
                VStack(alignment: .leading, spacing: 0) {
                    MeetingNoteView(note: note)
                        .id(note.id)
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            meetings.delete(note)
                            selectedID = nil
                        } label: {
                            Label("Delete", systemImage: "trash").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 10)
                }
                .padding(42)
                .frame(maxWidth: 860, alignment: .topLeading)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble").font(.system(size: 30)).foregroundStyle(CadenceTheme.muted)
                    Text("Select a meeting to read its transcript and notes.")
                        .font(.system(size: 14)).foregroundStyle(CadenceTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
