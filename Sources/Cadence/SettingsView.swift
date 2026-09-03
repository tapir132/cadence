@preconcurrency import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum RecognitionSettingsPage: String, CaseIterable, Identifiable {
    case profiles = "Profiles"
    case advanced = "Advanced"

    var id: String { rawValue }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updates = UpdateManager.shared
    @State private var recognitionSettingsPage: RecognitionSettingsPage = .profiles
    @State private var bugReportExportMessage: String?
    @State private var bugReportExportFailed = false
    @State private var exportedBugReportURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("PREFERENCES")
                    .font(.system(size: 10, weight: .bold)).tracking(1.8)
                    .foregroundStyle(CadenceTheme.muted)
                Text("Small controls. Fast flow.")
                    .font(.system(size: 40, weight: .medium, design: .serif))
                    .tracking(-1.4)
                    .padding(.top, 28)
                    .padding(.bottom, 36)

                sectionTitle("Permissions")
                VStack(spacing: 0) {
                    permissionRow("Microphone", detail: "Hear your voice", granted: model.microphoneAuthorized)
                    line
                    permissionRow("Accessibility", detail: "Paste into the focused app", granted: model.accessibilityAuthorized)
                }
                .settingsSurface()

                Button {
                    model.requestPermissions()
                } label: {
                    HStack(spacing: 7) {
                        if model.isRequestingPermissions { ProgressView().controlSize(.small) }
                        Text(model.isRequestingPermissions ? "Requesting permissions…" : "Request missing permissions")
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(CadenceTheme.ink)
                    .disabled(model.isRequestingPermissions)
                    .padding(.top, 12)

                if let message = model.permissionRequestMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(CadenceTheme.muted)
                        .padding(.top, 8)
                }

                sectionTitle("Recognition").padding(.top, 34)
                VStack(spacing: 0) {
                    speechModelRow
                    line
                    recognitionSettingsPageRow
                    line
                    if recognitionSettingsPage == .profiles {
                        dictationProfileRow
                        if model.dictationProfile == .essay {
                            line
                            characterPlaybackSpeedRow
                            line
                            characterPlaybackRhythmRow
                        }
                    } else {
                        recognitionProfileRow
                        line
                        speechCleanupRow
                        line
                        deepEditingRow
                        line
                        typingBufferRow
                        line
                        characterPlaybackRow
                        if model.characterPlaybackEnabled {
                            line
                            characterPlaybackSpeedRow
                            line
                            characterPlaybackRhythmRow
                        }
                    }
                }
                .settingsSurface()

                sectionTitle("Listening").padding(.top, 34)
                pauseMusicRow
                    .settingsSurface()

                sectionTitle("Global shortcut").padding(.top, 34)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hold to talk from any app").font(.system(size: 13, weight: .semibold))
                        Text("Hold the shortcut while you speak and release it to finish; Cadence stays out of the way.")
                            .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                        Text("Press a combination, a function key (hold fn if it controls volume), or tap modifier keys alone such as ⌃⌥ or ⌘.")
                            .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                        if model.shortcut.isModifierOnly, !model.accessibilityAuthorized {
                            Text("Modifier-only shortcuts work outside Cadence once Accessibility is granted.")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(CadenceTheme.coral)
                        }
                    }
                    Spacer()
                    ShortcutRecorder(shortcut: $model.shortcut)
                        .frame(width: 148, height: 32)
                }
                .padding(16)
                .settingsSurface()

                sectionTitle("Floating bar").padding(.top, 34)
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Screen position").font(.system(size: 13, weight: .semibold))
                                Text("Drag into one of eight edge slots. Hold Command while dragging for free placement.")
                                    .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                            }
                            Spacer()
                        }
                        HStack(spacing: 7) {
                            ForEach(BarPlacement.allCases) { placement in
                                Button {
                                    model.barPlacement = placement
                                } label: {
                                    VStack(spacing: 5) {
                                        Image(systemName: placement.icon).font(.system(size: 13, weight: .semibold))
                                        Text(placement.title).font(.system(size: 9, weight: .semibold))
                                    }
                                    .foregroundStyle(model.barPlacement == placement ? CadenceTheme.cream : CadenceTheme.ink.opacity(0.66))
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(model.barPlacement == placement ? CadenceTheme.ink : CadenceTheme.paperDeep.opacity(0.75))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)

                    line

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Bar size").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(Int(model.barScale * 100))%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(CadenceTheme.muted)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "capsule").font(.system(size: 9))
                            Slider(value: $model.barScale, in: 0.65...1.35, step: 0.05).tint(CadenceTheme.ink)
                            Image(systemName: "capsule.fill").font(.system(size: 17))
                        }
                        HStack {
                            Text("Resize live; Cadence remembers the size and free position per Mac.")
                                .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                            Spacer()
                            Button("Reset") { model.resetBarPosition() }.buttonStyle(.link)
                        }
                    }
                    .padding(16)

                }
                .settingsSurface()

                sectionTitle("Updates").padding(.top, 34)
                VStack(spacing: 0) {
                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Check automatically").font(.system(size: 13, weight: .semibold))
                            Text("Checks silently at launch and every six hours, then prompts when a newer signed build is available.")
                                .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                        }
                        Spacer(minLength: 18)
                        Toggle("Check automatically", isOn: $updates.automaticallyChecks)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Check automatically")
                    }
                    .padding(16)

                    line

                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Download and install automatically").font(.system(size: 13, weight: .semibold))
                            Text("Sparkle verifies the EdDSA signature before replacing Cadence.")
                                .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                        }
                        Spacer(minLength: 18)
                        Toggle("Download and install automatically", isOn: $updates.automaticallyDownloads)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Download and install automatically")
                    }
                    .disabled(!updates.automaticallyChecks)
                    .padding(16)

                    line

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cadence \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Updates are served from tapir132/cadence.")
                                .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                        }
                        Spacer()
                        Button("Check now") { updates.checkForUpdates() }
                            .buttonStyle(.bordered)
                            .disabled(!updates.canCheckForUpdates)
                    }
                    .padding(16)

                    line

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Update channel").font(.system(size: 13, weight: .semibold))
                            Text(updates.channel == .stable
                                 ? "Release installs tested, versioned Public Beta builds."
                                 : "Edge installs every successful build from main and may be unstable.")
                                .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                        }
                        Spacer()
                        Picker("Update channel", selection: $updates.channel) {
                            ForEach(UpdateChannel.allCases) { channel in
                                Text(channel.title).tag(channel)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                    .padding(16)
                }
                .settingsSurface()

                sectionTitle("Support").padding(.top, 34)
                bugReportRow
                    .settingsSurface()
            }
            .padding(42)
            .frame(maxWidth: 860, alignment: .leading)
        }
        // Grants change in System Settings while this page is visible, so poll
        // instead of reading once on appear; the task ends when the page closes.
        .task {
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold)).tracking(1.2)
            .foregroundStyle(CadenceTheme.muted)
            .padding(.bottom, 8)
    }

    private var line: some View { Rectangle().fill(CadenceTheme.line).frame(height: 1).padding(.leading, 16) }

    private var speechModelRow: some View {
        HStack(spacing: 12) {
            switch model.speechModelStatus {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(CadenceTheme.ink)
            case .preparing:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(CadenceTheme.coral)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Parakeet Unified English").font(.system(size: 13, weight: .semibold))
                switch model.speechModelStatus {
                case .ready:
                    Group {
                        Text("Ready · \(model.recognitionProfile.detail)")
                        Text("Live transcription runs entirely on this Mac.")
                        Text("Say “period,” “full stop,” or “question mark” to insert punctuation.")
                    }
                    .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                case let .preparing(progress):
                    Text(progress.map { "Preparing local model · \(Int($0 * 100))%" }
                         ?? "Preparing the local speech model…")
                        .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                case let .failed(message):
                    Text(message).lineLimit(2)
                        .font(.system(size: 11)).foregroundStyle(CadenceTheme.coral)
                }
            }
            Spacer()
            if case .failed = model.speechModelStatus {
                Button("Retry") { model.retrySpeechModelPreparation() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }

    private var recognitionProfileRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recognition profile").font(.system(size: 13, weight: .semibold))
                Text("Both use Parakeet Unified 0.6B. Accurate uses more context and may prepare one additional local encoder the first time; later switches keep both profiles warm.")
                    .font(.system(size: 11))
                    .foregroundStyle(CadenceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            Picker("Recognition profile", selection: $model.recognitionProfile) {
                ForEach(RecognitionProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 176)
            .disabled(model.isListening)
        }
        .padding(16)
    }

    private var recognitionSettingsPageRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Setup").font(.system(size: 13, weight: .semibold))
                Text("Start with a complete profile, or tune every behavior yourself.")
                    .font(.system(size: 11))
                    .foregroundStyle(CadenceTheme.muted)
            }
            Spacer(minLength: 18)
            Picker("Recognition settings", selection: $recognitionSettingsPage) {
                ForEach(RecognitionSettingsPage.allCases) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 210)
        }
        .padding(16)
    }

    private var dictationProfileRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                HStack(spacing: 7) {
                    Text("Dictation profile").font(.system(size: 13, weight: .semibold))
                    if model.dictationProfile == .normal {
                        Text("RECOMMENDED")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(CadenceTheme.muted)
                    }
                }
                Spacer(minLength: 18)
                Picker("Dictation profile", selection: dictationProfileBinding) {
                    ForEach(DictationProfile.presets) { profile in
                        Text(profile.title).tag(profile)
                    }
                    if model.dictationProfile == .custom {
                        Text("Custom").tag(DictationProfile.custom)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: model.dictationProfile == .custom ? 360 : 300)
                .disabled(model.isListening)
            }

            Text(model.dictationProfile.detail)
                .font(.system(size: 11))
                .foregroundStyle(CadenceTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.dictationProfile == .custom {
                Button("Review Advanced settings") {
                    recognitionSettingsPage = .advanced
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(16)
    }

    private var dictationProfileBinding: Binding<DictationProfile> {
        Binding(
            get: { model.dictationProfile },
            set: { profile in
                if profile == .custom {
                    recognitionSettingsPage = .advanced
                } else {
                    model.applyDictationProfile(profile)
                }
            }
        )
    }

    private var pauseMusicRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pause music while dictating")
                    .font(.system(size: 13, weight: .semibold))
                Text("Pauses Music and Spotify when listening starts, then resumes only playback Cadence paused. macOS may ask once for Automation access.")
                    .font(.system(size: 11))
                    .foregroundStyle(CadenceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            Toggle("Pause music while dictating", isOn: $model.pauseMusicDuringDictation)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Pause music while dictating")
        }
        .disabled(model.isListening)
        .padding(16)
    }

    private var bugReportRow: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export a bug report")
                    .font(.system(size: 13, weight: .semibold))
                Text("Saves app and macOS versions, permissions, settings, insertion status, and your three most recent transcripts. It never includes audio, clipboard contents, dictionary terms, or snippet text.")
                    .font(.system(size: 11))
                    .foregroundStyle(CadenceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let bugReportExportMessage {
                    HStack(spacing: 6) {
                        Image(systemName: bugReportExportFailed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        Text(bugReportExportMessage)
                        if let exportedBugReportURL, !bugReportExportFailed {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([exportedBugReportURL])
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(bugReportExportFailed ? CadenceTheme.coral : CadenceTheme.muted)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 18)
            Button {
                exportBugReport()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Export Cadence bug report")
        }
        .padding(16)
    }

    private func exportBugReport() {
        let generatedAt = Date()
        let report = model.makeBugReport(
            updateChannel: updates.channel,
            automaticallyChecksForUpdates: updates.automaticallyChecks,
            automaticallyDownloadsUpdates: updates.automaticallyDownloads,
            generatedAt: generatedAt
        )
        let data: Data
        do {
            data = try report.encodedData()
        } catch {
            exportedBugReportURL = nil
            bugReportExportFailed = true
            bugReportExportMessage = "Could not prepare the report: \(error.localizedDescription)"
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Cadence Bug Report"
        panel.prompt = "Export"
        panel.nameFieldStringValue = CadenceBugReport.suggestedFilename(at: generatedAt)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            exportedBugReportURL = url
            bugReportExportFailed = false
            bugReportExportMessage = "Saved \(url.lastPathComponent)"
        } catch {
            exportedBugReportURL = nil
            bugReportExportFailed = true
            bugReportExportMessage = "Could not save the report: \(error.localizedDescription)"
        }
    }

    private var speechCleanupRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("Filler-word cleanup").font(.system(size: 13, weight: .semibold))
                    Text("BETA")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(CadenceTheme.muted)
                }
                Text("Removes vocal pauses and punctuation-delimited asides such as “you know.” Context protects real uses such as “I like this.”")
                    .font(.system(size: 11))
                    .foregroundStyle(CadenceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            Toggle("Filler-word cleanup", isOn: $model.speechCleanupEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Filler-word cleanup")
        }
        .disabled(model.isListening)
        .padding(16)
    }

    private var typingBufferRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("One-second stability buffer").font(.system(size: 13, weight: .semibold))
                Text("Keeps the preview live, but waits one extra second before completed words reach your editor. Snippets do not require this; their triggers are held separately. Pauses and shortcut release still flush immediately.")
                    .font(.system(size: 11))
                    .foregroundStyle(CadenceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            Toggle("One-second stability buffer", isOn: $model.typingBufferEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("One-second stability buffer")
        }
        .disabled(model.isListening)
        .padding(16)
    }

    private var deepEditingRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("Deeper editing").font(.system(size: 13, weight: .semibold))
                    Text("BETA")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(CadenceTheme.muted)
                }
                Text("After you finish, uses repeated-word anchors, editing terms, and sentence grammar to repair clear restarts and false boundaries. It changes only a verified dictation span.")
                    .font(.system(size: 11))
                    .foregroundStyle(CadenceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            Toggle("Deeper editing", isOn: $model.deepEditingEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Deeper editing")
        }
        .disabled(model.isListening)
        .padding(16)
    }

    private var characterPlaybackRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("Essay-style character typing").font(.system(size: 13, weight: .semibold))
                    Text("BETA")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(CadenceTheme.muted)
                }
                Text("Delivers committed text one complete character at a time. Essay enables this; Quick and Normal paste complete chunks instead.")
                    .font(.system(size: 11))
                    .foregroundStyle(CadenceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            Toggle("Essay-style character typing", isOn: $model.characterPlaybackEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Essay-style character typing")
        }
        .disabled(model.isListening)
        .padding(16)
    }

    private var characterPlaybackSpeedRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Typing speed").font(.system(size: 13, weight: .semibold))
                Text("Sets the average character pace. Editors that do not expose cursor progress may type more slowly for reliability.")
                    .font(.system(size: 11))
                    .foregroundStyle(CadenceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            VStack(alignment: .trailing, spacing: 7) {
                Text("\(Int(model.characterPlaybackWordsPerMinute.rounded())) WPM")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CadenceTheme.muted)
                Slider(
                    value: $model.characterPlaybackWordsPerMinute,
                    in: CharacterPlaybackPacing.wordsPerMinuteRange,
                    step: 5
                )
                .tint(CadenceTheme.ink)
                .frame(width: 220)
                .accessibilityLabel("Character typing speed")
                .accessibilityValue("\(Int(model.characterPlaybackWordsPerMinute.rounded())) words per minute")
            }
        }
        .disabled(model.isListening || !model.characterPlaybackEnabled)
        .padding(16)
    }

    private var characterPlaybackRhythmRow: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Typing rhythm").font(.system(size: 13, weight: .semibold))
                Text(model.characterPlaybackRhythm.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(CadenceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            Picker("Typing rhythm", selection: $model.characterPlaybackRhythm) {
                ForEach(CharacterPlaybackRhythm.allCases) { rhythm in
                    Text(rhythm.title).tag(rhythm)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .accessibilityLabel("Typing rhythm")
        }
        .disabled(model.isListening || !model.characterPlaybackEnabled)
        .padding(16)
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? CadenceTheme.ink : CadenceTheme.coral)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
            }
            Spacer()
            Text(granted ? "READY" : "NEEDED")
                .font(.system(size: 9, weight: .bold)).tracking(1)
                .foregroundStyle(CadenceTheme.muted)
        }
        .padding(16)
    }
}

private extension View {
    func settingsSurface() -> some View {
        background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(CadenceTheme.line))
        )
    }
}
