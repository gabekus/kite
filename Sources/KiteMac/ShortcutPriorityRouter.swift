import AppKit
import KiteCore
import WebKit

/// Gives each shortcut its priority (Settings › Shortcuts, Arc's `KeyboardShortcutPriority`) when a web
/// page has the keys. Both engines hand a page a key before the menu bar: the web view claims it as a key
/// equivalent, and passes it on to the menu only if the page doesn't use it (CEF's OnKeyEvent → the main
/// menu; WebKit sends the same event through the app again). So:
/// - Prefer Kite (`overrideWebView`) runs the command here, before the web view sees the key.
/// - Prefer Websites (`low`) leaves it to that path.
/// - Use Both (`promptAfterConsumedByWebView`) leaves it to the page too, but when the page keeps it,
///   shows "Press ⌘D again to Pin Tab", and the next press runs Kite's command here.
///
/// BrowserWindow calls `takeBeforePage` from performKeyEquivalent, which AppKit (and `ui input` in the
/// background) calls before the window's views, so this works the same for Chromium and WebKit.
@MainActor
final class ShortcutPriorityRouter {
    static let shared = ShortcutPriorityRouter()

    private var gate = ShortcutPriorityGate()
    /// The last key given to a page, so WebKit's resend of an unused key isn't taken for a new press.
    private var handedToPage: (timestamp: TimeInterval, keyCode: UInt16)?
    private var observer: NSObjectProtocol?
    /// The last key whose command ran here instead of going to the page, for `ui input`'s report.
    private(set) weak var lastTaken: NSEvent?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: nil) { note in
            guard let item = note.userInfo?["MenuItem"] as? NSMenuItem, let action = KeyBindingsStore.action(of: item) else { return }
            MainActor.assumeIsolated { ShortcutPriorityRouter.shared.gate.commandRan(action) }
        }
    }

    /// True when Kite ran the key's command, so the page mustn't get it.
    func takeBeforePage(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown,
              !event.modifierFlags.isDisjoint(with: [.command, .control, .option, .function]),
              Self.pageHasKeys(window),
              let bindings = (NSApp.delegate as? AppDelegate)?.keyBindings,
              let item = MenuKeyDispatch.item(matching: event), let action = KeyBindingsStore.action(of: item)
        else { return false }
        // WebKit sends a key the page didn't use through the app again: it's on its way to the menu bar.
        if let handed = handedToPage, handed.timestamp == event.timestamp, handed.keyCode == event.keyCode { return false }
        switch bindings.bindings.priority(for: action) {
        case .low:
            break
        case .overrideWebView:
            if MenuKeyDispatch.perform(item, in: window) { return took(event) }
        case .promptAfterConsumedByWebView:
            let windowNumber = window.windowNumber
            if gate.press(action, window: windowNumber, at: event.timestamp, isRepeat: event.isARepeat) {
                if MenuKeyDispatch.perform(item, in: window) { return took(event) }
                break
            }
            guard !event.isARepeat, let shortcut = item.shortcut else { break }
            let pressed = event.timestamp, title = item.title
            Task { @MainActor [weak window] in
                try? await Task.sleep(for: .seconds(ShortcutPriorityGate.consumedDelay))
                guard self.gate.pageConsumed(action, window: windowNumber, pressedAt: pressed),
                      let controller = window?.windowController as? BrowserWindowController else { return }
                controller.showToast(ShortcutPriorityGate.prompt(shortcut: shortcut, title: title),
                                     action: ("Edit the shortcut", { SettingsWindowController.shared.show(.shortcuts) }))
            }
        }
        handedToPage = (event.timestamp, event.keyCode)
        return false
    }

    private func took(_ event: NSEvent) -> Bool {
        lastTaken = event
        return true
    }

    /// Whether the window's first responder is web content (a WKWebView, or Chromium's view in a CEF tab),
    /// the only place a page can want the key.
    static func pageHasKeys(_ window: NSWindow) -> Bool {
        var view = window.firstResponder as? NSView
        while let current = view {
            if current is WKWebView || NSStringFromClass(type(of: current)).contains("RenderWidgetHostView") { return true }
            view = current.superview
        }
        return false
    }
}
