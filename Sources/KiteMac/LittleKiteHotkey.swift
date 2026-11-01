import AppKit
import Carbon.HIToolbox
import KiteCore

/// Settings › Links › "Open Little Kite when I press ⌥⌘N in any app": New Little Kite Window's
/// shortcut as a system-wide hotkey, so it opens Little Kite from any app.
///
/// Arc 1.171 does this with a Carbon hotkey (`GlobalHotkeyListenerClient`, `EventHotKeyID`,
/// `registerLittleBrowserShortcut`), on by default (`globalLittleBrowserHotkeyEnabled`). A Carbon
/// hotkey needs no permission prompt (no Accessibility or Input Monitoring); while it's registered,
/// the shortcut reaches Kite instead of the frontmost app, as in Arc. It follows the menu item, so a
/// changed shortcut moves the hotkey and a removed one drops it.
@MainActor
final class LittleKiteHotkey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: KeyShortcut?
    private var defaultsObserver: NSObjectProtocol?
    private let onPress: () -> Void
    /// The menu item whose shortcut becomes the hotkey (File › New Little Kite Window).
    private let menuItem: () -> NSMenuItem?

    /// What's registered now, for diagnostics and tests.
    var registeredShortcut: KeyShortcut? { registered }

    init(menuItem: @escaping () -> NSMenuItem?, onPress: @escaping () -> Void) {
        self.menuItem = menuItem
        self.onPress = onPress
        installHandler()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    /// Registers, moves or drops the hotkey to match the setting and the menu item's shortcut.
    func update() {
        let wanted = Self.allowed && LittleKite.globalHotkeyEnabled(in: .standard) ? menuItem()?.shortcut : nil
        guard wanted != registered else { return }
        unregister()
        guard let wanted, let code = LittleKite.virtualKeyCode(for: wanted.key) else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4B4C_4B48), id: 1) // "KLKH"
        let status = RegisterEventHotKey(code, LittleKite.carbonModifiers(wanted.modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Kite: couldn't register \(wanted.displayString) for Little Kite (\(status))")
            return
        }
        hotKey = ref
        registered = wanted
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registered = nil
    }

    /// Test runs (`KITE_DIAGNOSTICS`) leave other apps' shortcuts alone unless asked with
    /// `KITE_TEST_GLOBAL_HOTKEY=1`: a hotkey is system wide, and test Kites run beside the user's work.
    private static var allowed: Bool {
        !UIDiagnostics.enabledByEnvironment || ProcessInfo.processInfo.environment["KITE_TEST_GLOBAL_HOTKEY"] == "1"
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<LittleKiteHotkey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotkey.onPress() }
            return noErr
        }, 1, &spec, context, &handler)
    }
}
