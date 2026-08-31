import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController {
    private let panel: NSPanel

    init(model: AppModel) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 88),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: FloatingBar().environmentObject(model))
        position()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.position() } }
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 24))
    }
}

struct FloatingBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var tick = false

    var body: some View {
        HStack(spacing: 10) {
            if model.isListening {
                Button { model.cancelDictation() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.28)))
                }
                .buttonStyle(.plain)

                WaveformMark(level: model.audioLevel, bars: 7)

                Text(model.liveText.isEmpty ? "Listening…" : model.liveText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(model.liveText.isEmpty ? Color.white.opacity(0.48) : CadenceTheme.cream)
                    .lineLimit(1)
                    .frame(maxWidth: 215, alignment: .leading)
                    .contentTransition(.numericText())

                Button { model.stopDictation() } label: {
                    Image(systemName: model.state == .finishing ? "ellipsis" : "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(CadenceTheme.ink)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(CadenceTheme.cream))
                }
                .buttonStyle(.plain)
            } else {
                Button { model.toggleDictation() } label: {
                    HStack(spacing: 8) {
                        BrandMark(size: 23)
                        Text(statusText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(CadenceTheme.cream)
                        HStack(spacing: 3) {
                            Text("⌃⌥")
                            Image(systemName: "space")
                        }
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.42))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, model.isListening ? 9 : 8)
        .frame(width: model.isListening ? 408 : 150, height: model.isListening ? 48 : 36)
        .background(
            Capsule()
                .fill(CadenceTheme.ink.opacity(0.97))
                .overlay(Capsule().stroke(Color(red: 0.3, green: 0.29, blue: 0.26), lineWidth: 1))
                .shadow(color: .black.opacity(0.24), radius: 16, y: 7)
        )
        .frame(width: 430, height: 88)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.isListening)
    }

    private var statusText: String {
        if case .error = model.state { return "Needs access" }
        return "Speak"
    }
}
