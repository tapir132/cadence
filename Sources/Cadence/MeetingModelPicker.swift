import SwiftUI

/// Shared by Settings and the Notes start screen so the model choice is
/// discoverable before recording, with ordinary keyboard-accessible controls.
struct MeetingModelPicker: View {
    @EnvironmentObject private var meetings: MeetingNotesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Meeting model").font(.system(size: 13, weight: .semibold))
                Text("Beta")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(CadenceTheme.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                Spacer(minLength: 0)
            }
            Picker("Meeting transcription model", selection: Binding(
                get: { meetings.recognitionModel },
                set: { meetings.selectRecognitionModel($0) }
            )) {
                ForEach(MeetingRecognitionModel.allCases) { model in
                    Text(model.title).tag(model).disabled(!model.isSupported)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(meetings.isRecording)
            .accessibilityIdentifier("meeting-model-picker")
            Text(meetings.isRecording ? "You can change models after this recording finishes." : meetings.recognitionModel.detail)
                .font(.system(size: 11))
                .foregroundStyle(CadenceTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !MeetingRecognitionModel.cohere.isSupported {
                Text("Cohere Beta requires macOS 15 or later.")
                    .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
            }
            setupStatus
        }
        .foregroundStyle(CadenceTheme.ink)
    }

    @ViewBuilder
    private var setupStatus: some View {
        let status = meetings.modelSetup.status(for: meetings.recognitionModel)
        VStack(alignment: .leading, spacing: 6) {
            switch status {
            case .idle:
                Text("Waiting for initial speech setup…")
                Button("Prepare meeting models") { meetings.prepareForMeetings() }
                    .buttonStyle(.bordered)
                    .disabled(meetings.isRecording)
            case .ready:
                Label("Ready on this Mac", systemImage: "checkmark.circle")
            case let .preparing(update):
                if update.phase == .downloading {
                    Text(update.progress.map { "Downloading models · \(Int($0 * 100))%" } ?? "Downloading models…")
                    ProgressView(value: update.progress)
                } else {
                    Text("Preparing models for meetings…")
                }
                if meetings.modelSetup.live == .ready {
                    Text("You can start now with Parakeet while Cohere finishes setup.")
                } else {
                    Text("First-time setup downloads the models once. Keep Cadence open to get ready.")
                }
            case let .failed(message):
                Text(meetings.modelSetup.live == .ready
                     ? "Cohere couldn't prepare. Notes can still use Parakeet."
                     : "Speech models couldn't prepare.")
                    .help(message)
                Button("Retry setup") { meetings.prepareForMeetings() }
                    .buttonStyle(.bordered)
                    .disabled(meetings.isRecording)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(CadenceTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("meeting-model-readiness")
    }
}
