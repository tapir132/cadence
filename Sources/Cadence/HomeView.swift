import AppKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var filteredRecords: [DictationRecord] {
        guard !query.isEmpty else { return model.records }
        return model.records.filter { $0.text.localizedCaseInsensitiveContains(query) || $0.appName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                hero
                metrics
                recent
            }
            .padding(.horizontal, 42)
            .padding(.bottom, 42)
            .frame(maxWidth: 970, alignment: .leading)
        }
    }

    private var topBar: some View {
        HStack {
            Text("VOICE WORKSPACE")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(CadenceTheme.muted)
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(CadenceTheme.muted)
                TextField("Search transcripts", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 150)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(Capsule().fill(Color.white.opacity(0.52)))
            .overlay(Capsule().stroke(CadenceTheme.line))
        }
        .padding(.top, 20)
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 30) {
            VStack(alignment: .leading, spacing: 13) {
                Text(greeting)
                    .font(.system(size: 44, weight: .medium, design: .serif))
                    .tracking(-1.6)
                    .foregroundStyle(CadenceTheme.ink)
                Text("Put your cursor anywhere. Hold the shortcut while you speak; Cadence types completed words live and finishes each sentence when you pause.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(CadenceTheme.muted)
                    .lineSpacing(3)
                    .frame(maxWidth: 500, alignment: .leading)
            }
            Spacer()
            Button { model.toggleFromHub() } label: {
                ZStack {
                    Circle()
                        .fill(model.isListening ? CadenceTheme.coral : CadenceTheme.ink)
                        .frame(width: 66, height: 66)
                    Image(systemName: model.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(CadenceTheme.cream)
                }
                .shadow(color: CadenceTheme.ink.opacity(0.18), radius: 18, y: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isListening ? "Stop dictation" : "Start dictation")
        }
        .padding(.top, 58)
        .padding(.bottom, 42)
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            metric(value: model.totalWords.formatted(), label: "words placed")
            divider
            metric(value: model.averageWPM == 0 ? "—" : "\(model.averageWPM)", label: "average WPM")
            divider
            metric(value: "\(model.records.count)", label: "dictations")
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 84)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CadenceTheme.ink)
        )
        .foregroundStyle(CadenceTheme.cream)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.13)).frame(width: 1, height: 34).padding(.horizontal, 28)
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 24, weight: .medium, design: .rounded))
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(minWidth: 90, alignment: .leading)
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent dictations")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .tracking(-0.5)
                Spacer()
                Text("Stored on this Mac")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CadenceTheme.muted)
            }
            .padding(.top, 36)
            .padding(.bottom, 14)

            if filteredRecords.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredRecords) { record in
                        RecordRow(record: record)
                        Rectangle().fill(CadenceTheme.line).frame(height: 1)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(CadenceTheme.paperDeep).frame(width: 46, height: 46)
                Image(systemName: "text.cursor").foregroundStyle(CadenceTheme.ink.opacity(0.62))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Your first words will land here")
                    .font(.system(size: 14, weight: .semibold))
                Text("Focus an editor, then hold \(model.shortcut.displayText) while you speak.")
                    .font(.system(size: 12)).foregroundStyle(CadenceTheme.muted)
            }
            Spacer()
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 4)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning. Speak freely." }
        if hour < 18 { return "Good afternoon. Speak freely." }
        return "Good evening. Speak freely."
    }
}

private struct RecordRow: View {
    @EnvironmentObject private var model: AppModel
    let record: DictationRecord
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(record.date, format: .dateTime.hour().minute())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(CadenceTheme.muted)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                Text(record.text)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .lineSpacing(3)
                HStack(spacing: 8) {
                    Text(record.appName)
                    Text("·")
                    Text("\(record.wordsPerMinute) WPM")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CadenceTheme.muted)
            }
            Spacer()
            HStack(spacing: 4) {
                Button { model.copy(record.text) } label: {
                    Image(systemName: "doc.on.doc").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy")
                Button { model.deleteRecord(record) } label: {
                    Image(systemName: "trash").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
            // Keep this gutter in the row at all times. Hovering should reveal
            // actions, never steal width from the transcript and reflow it.
            .frame(width: 52, alignment: .trailing)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .accessibilityHidden(!hovering)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
