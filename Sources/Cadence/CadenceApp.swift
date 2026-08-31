import AppKit
import SwiftUI

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppModel.shared)
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandMenu("Dictation") {
                Button(AppModel.shared.isListening ? "Stop Dictation" : "Start Dictation") {
                    AppModel.shared.toggleDictation()
                }
                .keyboardShortcut(.space, modifiers: [.control, .option])

                Button("Paste Last Transcript") {
                    AppModel.shared.pasteLastTranscript()
                }
                .keyboardShortcut("v", modifiers: [.control, .command])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var floatingPanel: FloatingPanelController?
    private var statusItem: NSStatusItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastShortcutAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureMainWindow()
        floatingPanel = FloatingPanelController(model: AppModel.shared)
        configureStatusItem()
        installShortcutMonitors()
        AppModel.shared.refreshPermissions()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureMainWindow() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
            window.title = "Cadence"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(red: 0.955, green: 0.945, blue: 0.915, alpha: 1)
            window.setFrameAutosaveName("CadenceMainWindow")
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Cadence")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Cadence", action: #selector(openApp), keyEquivalent: "")
        menu.addItem(withTitle: "Start / Stop Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        menu.addItem(withTitle: "Paste Last Transcript", action: #selector(pasteLast), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cadence", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func installShortcutMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option]
            else { return }
            self?.handleShortcut()
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            handler(event)
            if event.keyCode == 49,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] {
                self?.handleShortcut()
                return nil
            }
            return event
        }
    }

    private func handleShortcut() {
        guard Date().timeIntervalSince(lastShortcutAt) > 0.35 else { return }
        lastShortcutAt = Date()
        AppModel.shared.toggleDictation()
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleDictation() { AppModel.shared.toggleDictation() }
    @objc private func pasteLast() { AppModel.shared.pasteLastTranscript() }
}
