import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "rectangle.stack"
        case .dictionary: "text.book.closed"
        case .snippets: "scissors"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ZStack {
                CadenceTheme.paper.ignoresSafeArea()
                Group {
                    switch model.selectedSection {
                    case .home: HomeView()
                    case .dictionary: DictionaryView()
                    case .snippets: SnippetsView()
                    case .settings: SettingsView()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))

                if case let .error(message) = model.state {
                    VStack {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(CadenceTheme.coral)
                            Text(message)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(2)
                            Spacer()
                            Button { model.dismissError() } label: {
                                Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.white.opacity(0.94))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(CadenceTheme.line))
                                .shadow(color: CadenceTheme.ink.opacity(0.1), radius: 12, y: 5)
                        )
                        .padding(16)
                        Spacer()
                    }
                }
            }
        }
        .background(CadenceTheme.paper)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                Text("cadence")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .tracking(-0.7)
                    .foregroundStyle(CadenceTheme.cream)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 28)

            Text("WRITE")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Color.white.opacity(0.35))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            sidebarButton(.home)
            sidebarButton(.dictionary)
            sidebarButton(.snippets)

            Spacer()

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Circle().fill(sidebarStatus.color).frame(width: 7, height: 7)
                    Text(sidebarStatus.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.68))
                }
                HStack(spacing: 4) {
                    ForEach(Array(model.shortcut.modifierGlyphs), id: \.self) { glyph in
                        KeyboardKey(text: String(glyph), dark: true)
                    }
                    if !model.shortcut.keyLabel.isEmpty {
                        KeyboardKey(text: model.shortcut.keyLabel, dark: true)
                    }
                }
            }
            .padding(18)

            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1)
            sidebarButton(.settings)
                .padding(.vertical, 8)
        }
        .frame(width: 202)
        .background(CadenceTheme.ink)
    }

    private func sidebarButton(_ section: SidebarSection) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { model.selectedSection = section }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: section.icon).frame(width: 18)
                Text(section.rawValue).font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundStyle(model.selectedSection == section ? CadenceTheme.cream : Color.white.opacity(0.48))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(model.selectedSection == section ? Color.white.opacity(0.095) : .clear)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sidebarStatus: (text: String, color: Color) {
        switch model.state {
        case .listening:
            ("Listening now", CadenceTheme.coral)
        case .finishing:
            ("Finishing dictation…", CadenceTheme.coral)
        case .error:
            ("Needs attention", CadenceTheme.coral)
        case .idle:
            switch model.speechModelStatus {
            case .ready:
                ("Ready to dictate", CadenceTheme.lime)
            case .preparing:
                ("Preparing model…", CadenceTheme.coral)
            case .failed:
                ("Model unavailable", CadenceTheme.coral)
            }
        }
    }
}
