import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case dictionary = "Dictionary"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "rectangle.stack"
        case .dictionary: "text.book.closed"
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
                    case .settings: SettingsView()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
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

            Spacer()

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Circle().fill(model.isListening ? CadenceTheme.coral : CadenceTheme.lime).frame(width: 7, height: 7)
                    Text(model.isListening ? "Listening now" : "Ready to dictate")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.68))
                }
                HStack(spacing: 4) {
                    ForEach(Array(model.shortcut.modifierGlyphs), id: \.self) { glyph in
                        KeyboardKey(text: String(glyph), dark: true)
                    }
                    KeyboardKey(text: model.shortcut.keyLabel, dark: true)
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
        }
        .buttonStyle(.plain)
    }
}
