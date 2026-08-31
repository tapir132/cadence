import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

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
                    permissionRow("Speech Recognition", detail: "Turn audio into partial words", granted: model.speechAuthorized)
                    line
                    permissionRow("Accessibility", detail: "Type into the focused app", granted: model.accessibilityAuthorized)
                }
                .settingsSurface()

                Button("Request missing permissions") { model.requestPermissions() }
                    .buttonStyle(.borderedProminent)
                    .tint(CadenceTheme.ink)
                    .padding(.top, 12)

                sectionTitle("Recognition").padding(.top, 34)
                VStack(spacing: 0) {
                    Toggle(isOn: $model.useOnDeviceRecognition) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Prefer on-device recognition").font(.system(size: 13, weight: .semibold))
                            Text("Keeps audio local when the selected language is available offline.")
                                .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(16)
                    .onChange(of: model.useOnDeviceRecognition) { _, _ in model.saveSettings() }
                }
                .settingsSurface()

                sectionTitle("Typing cadence").padding(.top, 34)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Character spacing").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(Int(model.characterDelayMilliseconds)) ms")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CadenceTheme.muted)
                    }
                    Slider(value: $model.characterDelayMilliseconds, in: 2...18, step: 1)
                        .tint(CadenceTheme.ink)
                        .onChange(of: model.characterDelayMilliseconds) { _, _ in model.saveSettings() }
                    Text("Each character is emitted as a keyboard event. Slower spacing creates finer-grained document history.")
                        .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                }
                .padding(16)
                .settingsSurface()

                sectionTitle("Global shortcut").padding(.top, 34)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start or stop from any app").font(.system(size: 13, weight: .semibold))
                        Text("Keep your cursor in the document; Cadence stays out of the way.")
                            .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        KeyboardKey(text: "⌃")
                        KeyboardKey(text: "⌥")
                        KeyboardKey(text: "Space")
                    }
                }
                .padding(16)
                .settingsSurface()
            }
            .padding(42)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onAppear { model.refreshPermissions() }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold)).tracking(1.2)
            .foregroundStyle(CadenceTheme.muted)
            .padding(.bottom, 8)
    }

    private var line: some View { Rectangle().fill(CadenceTheme.line).frame(height: 1).padding(.leading, 16) }

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
