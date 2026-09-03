import SwiftUI

private enum StylePage: Hashable, Identifiable {
    case context(WritingContext)
    case cleanup

    var id: String {
        switch self {
        case let .context(context): context.rawValue
        case .cleanup: "cleanup"
        }
    }

    var title: String {
        switch self {
        case let .context(context): context.title
        case .cleanup: "Auto cleanup"
        }
    }

    static let all: [StylePage] = WritingContext.allCases.map(StylePage.context) + [.cleanup]
}

struct StyleView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page: StylePage = .context(.personalMessages)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("STYLE")
                    .font(.system(size: 10, weight: .bold)).tracking(1.8)
                    .foregroundStyle(CadenceTheme.muted)
                Text("Match the room.")
                    .font(.system(size: 40, weight: .medium, design: .serif))
                    .tracking(-1.4)
                    .padding(.top, 28)
                Text("Cadence recognizes the app you are dictating into and applies the tone you chose for it. A tone changes only capitalization and punctuation, never your words.")
                    .font(.system(size: 13)).foregroundStyle(CadenceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                tabs.padding(.top, 30)

                switch page {
                case let .context(context):
                    banner(
                        title: context.banner,
                        detail: "Style formatting applies to English dictation.",
                        trailing: context.exampleApps
                    )
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(context.tones) { tone in
                            toneCard(tone, context: context)
                        }
                    }
                    .padding(.top, 18)
                case .cleanup:
                    banner(
                        title: "Auto cleanup applies to all your dictations",
                        detail: "Choose how much Cadence tidies every time, across all apps. This is the same setting the Quick, Normal, and Essay profiles use, so changing it here can switch the profile to Custom.",
                        trailing: nil
                    )
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(AutoCleanupLevel.allCases) { level in
                            cleanupCard(level)
                        }
                    }
                    .padding(.top, 18)
                }
            }
            .padding(42)
            .frame(maxWidth: 860, alignment: .leading)
            .disabled(model.isListening)
        }
    }

    private var tabs: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 22) {
                ForEach(StylePage.all) { candidate in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { page = candidate }
                    } label: {
                        VStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Text(candidate.title)
                                    .font(.system(size: 13, weight: page == candidate ? .semibold : .medium))
                                if candidate == .cleanup {
                                    Text("BETA")
                                        .font(.system(size: 8, weight: .bold)).tracking(0.8)
                                        .foregroundStyle(CadenceTheme.muted)
                                }
                            }
                            .foregroundStyle(page == candidate ? CadenceTheme.ink : CadenceTheme.muted)
                            Rectangle()
                                .fill(page == candidate ? CadenceTheme.ink : .clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Rectangle().fill(CadenceTheme.line).frame(height: 1)
        }
    }

    private func banner(title: String, detail: String, trailing: String?) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .medium, design: .serif))
                    .tracking(-0.6)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
        .foregroundStyle(CadenceTheme.cream)
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CadenceTheme.ink)
        )
        .padding(.top, 22)
    }

    private func toneCard(_ tone: WritingTone, context: WritingContext) -> some View {
        let selected = model.writingStyles.tone(for: context) == tone
        return Button {
            model.setWritingTone(tone, for: context)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(tone.title).font(.system(size: 13, weight: .semibold))
                Text(tone.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(CadenceTheme.muted)
                    .padding(.top, 4)
                Spacer(minLength: 26)
                Text(tone.sample(for: context))
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(CadenceTheme.paperDeep.opacity(0.7))
                    )
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SelectableCard(selected: selected))
        .accessibilityLabel("\(tone.title) \(tone.subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cleanupCard(_ level: AutoCleanupLevel) -> some View {
        let selected = model.autoCleanupLevel == level
        return Button {
            model.autoCleanupLevel = level
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(level.title)
                    .font(.system(size: 24, weight: .medium, design: .serif))
                    .tracking(-0.6)
                Text(level.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(CadenceTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                Spacer(minLength: 26)
                Text(level.sample)
                    .font(.system(size: 12, design: .serif))
                    .italic()
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(CadenceTheme.paperDeep.opacity(0.7))
                    )
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(SelectableCard(selected: selected))
        .accessibilityLabel("\(level.title) cleanup")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SelectableCard: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.8 : 0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(selected ? CadenceTheme.ink : CadenceTheme.line, lineWidth: selected ? 2 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: selected)
    }
}
