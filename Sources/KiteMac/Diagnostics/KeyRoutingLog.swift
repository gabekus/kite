import AppKit
import KiteCore

/// `ui key_log`: the last 500 key presses in Kite and where each one went: the window and
/// first responder it reached, the input source, and any menu item it fired.
///
/// Runs only while Diagnostics for Claude is on. It's what would have caught a plain "e"
/// in a page opening Edit › Emoji & Symbols: the log shows the key firing that menu item.
///
/// Typing stays private: a printable key pressed without ⌘, ⌃ or ⌥ is logged as its kind
/// (letter, digit, symbol) unless it fired a menu item, since then it's a shortcut bug and
/// the key is the point. Claude's own synthetic keys are logged in full.
@MainActor
final class KeyRoutingLog {
    struct Entry {
        let id: Int
        let time: Date
        /// The event's own timestamp, which a menu action later in the same dispatch carries too.
        let timestamp: TimeInterval
        let keyCode: UInt16
        let key: String
        let isPlainTyping: Bool
        let isRepeat: Bool
        let synthetic: Bool
        let window: String
        let responder: String
        let inputSource: String?
        var routes: [String] = []
    }

    static let capacity = 500

    private var entries: [Entry] = []
    private var nextID = 1
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    /// The synthetic key being delivered right now, which owns any menu action it sets off.
    private var delivering: Int?

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.record(event, synthetic: false) }
            return event
        }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: nil) {
            [weak self] note in
            guard let item = note.userInfo?["MenuItem"] as? NSMenuItem else { return }
            MainActor.assumeIsolated { self?.menuFired(item) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        monitor = nil
        observer = nil
        entries.removeAll()
    }

    @discardableResult
    func record(_ event: NSEvent, synthetic: Bool) -> Int {
        // A view that claimed a synthetic key may send the same event through the app later; it's the same press.
        if !synthetic, let earlier = entries.last(where: { $0.synthetic && $0.timestamp == event.timestamp && $0.keyCode == event.keyCode }) {
            return earlier.id
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
        let plain = flags.isDisjoint(with: [.command, .control, .option]) && Self.isPrintable(event)
        let id = nextID
        nextID += 1
        let window = event.window ?? NSApp.window(withWindowNumber: event.windowNumber)
        entries.append(Entry(
            id: id, time: Date(), timestamp: event.timestamp, keyCode: event.keyCode, key: Self.describe(event, flags: flags),
            isPlainTyping: plain, isRepeat: event.isARepeat, synthetic: synthetic,
            window: window.map { "\($0.windowNumber) \(UIFormat.className(($0.windowController ?? $0) as AnyObject))" } ?? "none",
            responder: Self.responderChain(window?.firstResponder),
            inputSource: NSTextInputContext.current?.selectedKeyboardInputSource.map(Self.shortSource)
        ))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        return id
    }

    /// Runs `deliver` with menu actions credited to entry `id`.
    func whileDelivering<T>(_ id: Int, _ deliver: () -> T) -> T {
        delivering = id
        defer { delivering = nil }
        return deliver()
    }

    func routes(of id: Int) -> [String] {
        entries.first { $0.id == id }?.routes ?? []
    }

    private func menuFired(_ item: NSMenuItem) {
        let index: Int?
        if let delivering {
            index = entries.lastIndex { $0.id == delivering }
        } else if let event = NSApp.currentEvent, event.type == .keyDown {
            // CEF hands unhandled page keys to the menu bar later, with the original event.
            index = entries.lastIndex { $0.timestamp == event.timestamp && $0.keyCode == event.keyCode }
        } else {
            index = nil
        }
        guard let index else { return }
        let action = item.action.map { NSStringFromSelector($0) } ?? "no action"
        entries[index].routes.append("menu \(UIMenuReader.path(of: item).joined(separator: " > ")) (\(action))")
    }

    func report(limit: Int, clear: Bool) -> String {
        defer { if clear { entries.removeAll() } }
        guard isRunning else { return "The key log isn't running (Diagnostics for Claude is off)." }
        let shown = entries.suffix(limit)
        guard !shown.isEmpty else { return "No keys pressed in Kite since the log started." }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let lines = shown.map { entry -> String in
            let key = entry.isPlainTyping && !entry.synthetic && entry.routes.isEmpty ? Self.kind(of: entry.key) : entry.key
            var parts = ["\(formatter.string(from: entry.time)) \(key) (keyCode \(entry.keyCode))"]
            if entry.isRepeat { parts.append("repeat") }
            if entry.synthetic { parts.append("synthetic") }
            parts.append("window \(entry.window)")
            parts.append("responder \(entry.responder)")
            if let source = entry.inputSource { parts.append("input \(source)") }
            parts += entry.routes.map { "→ \($0)" }
            return parts.joined(separator: " | ")
        }
        return "\(shown.count) of \(entries.count) logged keys, oldest first. Plain typing shows only its kind.\n"
            + UntrustedContent.wrap(lines.joined(separator: "\n"), source: "Kite key log")
    }

    // MARK: Formatting

    private static func isPrintable(_ event: NSEvent) -> Bool {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }

    private static func describe(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> String {
        var prefix = ""
        if flags.contains(.function) && !(event.specialKey != nil) { prefix += "fn " }
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }
        let key = UIMenuItem.keyName(event.charactersIgnoringModifiers ?? "?")
        let typed = event.characters.flatMap { $0 != event.charactersIgnoringModifiers && !$0.isEmpty ? " types \"\($0)\"" : nil } ?? ""
        return prefix + key + typed
    }

    private static func kind(of key: String) -> String {
        guard let character = key.first else { return "key" }
        if character.isLetter { return "‹letter›" }
        if character.isNumber { return "‹digit›" }
        if character == " " || key.hasPrefix("Space") { return "‹space›" }
        return "‹symbol›"
    }

    private static func responderChain(_ responder: NSResponder?) -> String {
        var names: [String] = []
        var current = responder
        while let next = current, names.count < 3 {
            names.append(UIFormat.className(next))
            current = next.nextResponder
        }
        return names.isEmpty ? "none" : names.joined(separator: " ← ")
    }

    private static func shortSource(_ id: String) -> String {
        id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    }
}

/// Reads the menu bar for `ui menu`.
@MainActor
enum UIMenuReader {
    static func items() -> [UIMenuItem] {
        guard let main = NSApp.mainMenu else { return [] }
        var result: [UIMenuItem] = []
        func visit(_ menu: NSMenu, path: [String]) {
            // Validates every item, as opening the menu would.
            menu.update()
            for item in menu.items where !item.isSeparatorItem {
                let title = item.title.isEmpty ? (item.isHidden ? "(hidden alternate)" : "(untitled)") : item.title
                let itemPath = path + [title]
                if let submenu = item.submenu {
                    visit(submenu, path: itemPath)
                    continue
                }
                var key = item.keyEquivalent
                var modifiers = names(item.keyEquivalentModifierMask)
                // An uppercase key equivalent means ⇧ too.
                if key.count == 1, let character = key.first, character.isUppercase {
                    modifiers.insert("shift")
                    key = key.lowercased()
                }
                result.append(UIMenuItem(
                    path: itemPath, key: key, modifiers: key.isEmpty ? [] : modifiers,
                    action: item.action.map { NSStringFromSelector($0) },
                    target: item.target.map { UIFormat.className($0 as AnyObject) },
                    identifier: item.identifier?.rawValue, isEnabled: item.isEnabled, isHidden: item.isHidden, isOn: item.state == .on
                ))
            }
        }
        visit(main, path: [])
        return result
    }

    static func names(_ mask: NSEvent.ModifierFlags) -> Set<String> {
        var names: Set<String> = []
        if mask.contains(.command) { names.insert("cmd") }
        if mask.contains(.control) { names.insert("ctrl") }
        if mask.contains(.option) { names.insert("alt") }
        if mask.contains(.shift) { names.insert("shift") }
        if mask.contains(.function) { names.insert("fn") }
        return names
    }

    static func path(of item: NSMenuItem) -> [String] {
        var path = [item.title]
        var menu = item.menu
        while let current = menu, let parent = current.supermenu {
            if let owner = parent.items.first(where: { $0.submenu === current }) { path.insert(owner.title, at: 0) }
            menu = parent
        }
        return path
    }
}
