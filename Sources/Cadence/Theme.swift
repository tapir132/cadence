import SwiftUI

enum CadenceTheme {
    static let ink = Color(red: 0.095, green: 0.098, blue: 0.09)
    static let paper = Color(red: 0.965, green: 0.955, blue: 0.925)
    static let paperDeep = Color(red: 0.91, green: 0.895, blue: 0.85)
    static let cream = Color(red: 1.0, green: 1.0, blue: 0.92)
    static let lime = Color(red: 0.76, green: 0.93, blue: 0.42)
    static let coral = Color(red: 0.96, green: 0.37, blue: 0.25)
    static let muted = Color(red: 0.43, green: 0.43, blue: 0.40)
    static let line = Color.black.opacity(0.11)
}

struct WaveformMark: View {
    var level: Float = 0.45
    var color: Color = CadenceTheme.cream
    var bars = 7

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2.3, height: height(for: index))
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }

    private func height(for index: Int) -> CGFloat {
        let pattern: [CGFloat] = [0.32, 0.66, 0.48, 1, 0.72, 0.5, 0.28]
        let base = pattern[index % pattern.count]
        let live = max(CGFloat(level), 0.14)
        return max(3, 19 * base * (0.5 + live * 0.75))
    }
}

struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .fill(CadenceTheme.lime)
            WaveformMark(level: 0.75, color: CadenceTheme.ink, bars: 5)
                .scaleEffect(size / 38)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Cadence")
    }
}

struct KeyboardKey: View {
    let text: String
    var dark = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(dark ? CadenceTheme.cream : CadenceTheme.ink.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(dark ? Color.white.opacity(0.1) : Color.white.opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(dark ? 0 : 0.12)))
            )
    }
}
