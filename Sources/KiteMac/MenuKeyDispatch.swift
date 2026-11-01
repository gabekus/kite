import AppKit

/// Runs the menu command a key matches on one window's responder chain, whether or not that window is
/// key: what the menu bar does for the key window, for `ui input` in the background and for shortcuts
/// that Kite runs before a page sees them (ShortcutPriorityRouter).
@MainActor
enum MenuKeyDispatch {
    /// The menu item whose key equivalent matches `event`: same key, same ⌘⌃⌥⇧ (an uppercase equivalent implies ⇧).
    static func item(matching event: NSEvent, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        guard let menu else { return nil }
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let flags = event.modifierFlags.intersection(modifiers)
        let key = event.charactersIgnoringModifiers?.lowercased()
        for item in menu.items {
            if let submenu = item.submenu, let found = Self.item(matching: event, in: submenu) { return found }
            guard !item.keyEquivalent.isEmpty, item.keyEquivalent.lowercased() == key else { continue }
            var mask = item.keyEquivalentModifierMask.intersection(modifiers)
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            if mask == flags { return item }
        }
        return nil
    }

    /// Validates and runs `item` for `window`, as the menu bar would; false if it's disabled or nothing answers it.
    @discardableResult
    static func perform(_ item: NSMenuItem, in window: NSWindow) -> Bool {
        guard let action = item.action else { return false }
        // An item with a target (the MenuRouter) still runs when AppKit's menu bar, inactive in the background,
        // won't: validated by its target, as the menu bar would.
        if let target = item.target {
            if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) { return false }
            NSApp.sendAction(action, to: target, from: item)
            NotificationCenter.default.post(name: NSMenu.didSendActionNotification, object: item.menu, userInfo: ["MenuItem": item])
            return true
        }
        var responder = window.firstResponder
        while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
        // Past the window: the app and its delegate (Hide Kite, Quit Kite), as AppKit's own chain goes.
        let target: AnyObject? = responder
            ?? (NSApp.responds(to: action) ? NSApp : nil)
            ?? ((NSApp.delegate as? NSObject)?.responds(to: action) == true ? NSApp.delegate : nil)
        guard let target else { return false }
        if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) { return false }
        if let validator = target as? NSUserInterfaceValidations, !validator.validateUserInterfaceItem(item) { return false }
        NSApp.sendAction(action, to: target, from: item)
        // The key log credits menu commands through this notification.
        NotificationCenter.default.post(name: NSMenu.didSendActionNotification, object: item.menu, userInfo: ["MenuItem": item])
        return true
    }
}
