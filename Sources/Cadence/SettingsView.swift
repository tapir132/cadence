import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updates = UpdateManager.shared

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
                    Slider(value: $model.characterDelayMilliseconds, in: 1...16, step: 1)
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
                    Toggle(isOn: $updates.automaticallyChecks) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Check automatically").font(.system(size: 13, weight: .semibold))
                            Text("Looks for signed GitHub releases every six hours.")
                                .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(16)

                    line

                    Toggle(isOn: $updates.automaticallyDownloads) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Download and install automatically").font(.system(size: 13, weight: .semibold))
                            Text("Sparkle verifies the EdDSA signature before replacing Cadence.")
                                .font(.system(size: 11)).foregroundStyle(CadenceTheme.muted)
                        }
                    }
                    .toggleStyle(.switch)
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
