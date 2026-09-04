import SwiftUI

struct TyperView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("typerDraft") private var draft = ""

    private var wordCount: Int { draft.wordCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TYPER")
                .font(.system(size: 10, weight: .bold)).tracking(1.8)
                .foregroundStyle(CadenceTheme.muted)
            Text("Type it in for you.")
                .font(.system(size: 40, weight: .medium, design: .serif))
                .tracking(-1.4)
                .padding(.top, 28)
            Text("Paste or dictate text below, click into the document that should receive it, then come back and press Start. Cadence steps out of the way and types it there one character at a time at your Essay pace. Press your dictation shortcut to stop early.")
                .font(.system(size: 13)).foregroundStyle(CadenceTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            TextEditor(text: $draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 240, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(CadenceTheme.line))
                .padding(.top, 28)

            HStack(spacing: 18) {
                Text("\(wordCount) words · \(draft.count) characters")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CadenceTheme.muted)
                Spacer()
                Text("\(Int(model.characterPlaybackWordsPerMinute.rounded())) WPM · \(model.characterPlaybackRhythm.title)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CadenceTheme.muted)
                Button("Change pace") {
                    withAnimation(.easeOut(duration: 0.18)) { model.selectedSection = .settings }
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .semibold))
                Button {
                    model.startTyping(draft)
                } label: {
                    Label("Start", systemImage: "keyboard")
                }
                .buttonStyle(.borderedProminent)
                .tint(CadenceTheme.ink)
                .controlSize(.large)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isListening || model.isTyping)
            }
            .padding(.top, 14)

            if let typing = model.typing {
                HStack(spacing: 14) {
                    ProgressView(value: Double(typing.deliveredCharacters), total: Double(max(typing.totalCharacters, 1)))
                        .tint(CadenceTheme.ink)
                    Text("Typing into \(typing.appName) · \(typing.deliveredCharacters) of \(typing.totalCharacters)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CadenceTheme.muted)
                        .frame(minWidth: 220, alignment: .leading)
                    Button("Stop") { model.cancelTyping() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 16)
            }
        }
        .padding(42)
        .frame(maxWidth: 860, maxHeight: .infinity, alignment: .topLeading)
    }
}
