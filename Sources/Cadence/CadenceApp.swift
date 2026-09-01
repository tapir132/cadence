import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let updateManager = UpdateManager.shared

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
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppModel.shared.selectedSection = .settings
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updateManager.checkForUpdates() }
                    .disabled(!updateManager.canCheckForUpdates)
            }
            CommandMenu("Dictation") {
                Button(AppModel.shared.isListening ? "Stop Dictation" : "Start Dictation") {
                    AppModel.shared.toggleDictation()
                }

                Button("Paste Last Transcript") {
                    AppModel.shared.pasteLastTranscript()
                }
                .keyboardShortcut("v", modifiers: [.control, .command])
            }
        }
    }
}

/// Carbon hot keys are delivered by the window server, so they work without
/// Accessibility trust (which an ad-hoc-signed build loses on every rebuild)
/// and the keystroke is consumed instead of also reaching the focused editor.
/// `NSEvent` global monitors silently need that trust and cannot consume.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var binding: ShortcutBinding? { didSet { register() } }
    var isSuspended = false { didSet { register() } }
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private(set) var isRegistered = false

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isDown = false
    private var monitors: [Any] = []

    private func register() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        isDown = false
        isRegistered = false
        guard let binding, !isSuspended else { return }
        if let keyCode = binding.keyCode {
            registerCarbonHotKey(keyCode: keyCode, binding: binding)
        } else {
            registerModifierChord()
        }
    }

    private func registerCarbonHotKey(keyCode: UInt16, binding: ShortcutBinding) {
        installHandler()
        let hotKeyID = EventHotKeyID(signature: 0x4344_4E43, id: 1) // "CDNC"
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            binding.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        isRegistered = status == noErr
        if !isRegistered {
            NSLog("Cadence could not register the %@ hot key (OSStatus %d)", binding.displayText, status)
        }
    }

    /// Carbon cannot express a modifier-only chord, so those are observed with
    /// event monitors. Global monitors need Accessibility trust, which typing
    /// into other apps already requires.
    private func registerModifierChord() {
        let flags: (NSEvent) -> Void = { [weak self] event in
            self?.handleFlags(event.modifierFlags.intersection(ShortcutBinding.shortcutModifiers))
        }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 }
        ].compactMap { $0 }
        isRegistered = monitors.count == 2
    }

    /// A chord is down once exactly its modifiers are held, and up as soon as
    /// any of them lifts. Reaching it through a larger combination never starts it.
    func handleFlags(_ current: NSEvent.ModifierFlags) {
        guard let binding, binding.isModifierOnly else { return }
        if !isDown, current == binding.modifiers {
            isDown = true
            onPress?()
        } else if isDown, !current.isSuperset(of: binding.modifiers) {
            isDown = false
            onRelease?()
        }
    }

    /// Carbon repeats press events while the key is held; only edges matter.
    func handleCarbon(isPress: Bool) {
        guard isPress != isDown else { return }
        isDown = isPress
        if isPress { onPress?() } else { onRelease?() }
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        let specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { GlobalHotKey.shared.handleCarbon(isPress: isPress) }
            return noErr
        }, specs.count, specs, nil, &handlerRef)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var floatingPanel: FloatingPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureApplicationIcon()
        UpdateManager.shared.start()
        configureMainWindow()
        floatingPanel = FloatingPanelController(model: AppModel.shared)
        configureStatusItem()
        GlobalHotKey.shared.onPress = { AppModel.shared.shortcutPressed() }
        GlobalHotKey.shared.onRelease = { AppModel.shared.shortcutReleased() }
        GlobalHotKey.shared.binding = AppModel.shared.shortcut
        AppModel.shared.refreshPermissions()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openApp() }
        return true
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

    private func configureApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "Cadence", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Cadence")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Cadence", action: #selector(openApp), keyEquivalent: "")
        menu.addItem(withTitle: "Start / Stop Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        menu.addItem(withTitle: "Paste Last Transcript", action: #selector(pasteLast), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cadence", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleDictation() { AppModel.shared.toggleDictation() }
    @objc private func pasteLast() { AppModel.shared.pasteLastTranscript() }
    @objc private func openSettings() {
        AppModel.shared.selectedSection = .settings
        openApp()
    }
    @objc private func checkForUpdates() { UpdateManager.shared.checkForUpdates() }
}
