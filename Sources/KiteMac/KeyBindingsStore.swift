import AppKit
import KiteCore

/// Shortcut overrides on disk (keybindings.json), applied to the menu bar.
/// Every shortcut in Kite is a menu item's key equivalent, so changing the
/// item changes the shortcut, the menu, the command bar and Keyboard Shortcuts.
@MainActor
final class KeyBindingsStore {
    private(set) var bindings = KeyBindings()
    private let fileURL: URL
    /// Each item's shortcut as MainMenu built it, so a reset can put it back.
    private var defaults: [ObjectIdentifier: KeyShortcut?] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            bindings = try JSONDecoder().decode(KeyBindings.self, from: data)
        } catch {
            NSLog("Kite: couldn't read key bindings, using defaults: \(error)")
        }
    }

    func set(_ override: KeyBindingOverride, menu: NSMenu?) {
        bindings.set(override)
        save()
        apply(to: menu)
    }

    /// Adds several overrides at once, replacing any for the same actions.
    func merge(_ overrides: [KeyBindingOverride], menu: NSMenu?) {
        overrides.forEach { bindings.set($0) }
        save()
        apply(to: menu)
    }

    func reset(_ action: String, menu: NSMenu?) {
        bindings.reset(action)
        save()
        apply(to: menu)
    }

    /// Removes every override, so each command has its default shortcut again.
    func resetAll(menu: NSMenu?) {
        bindings = KeyBindings()
        save()
        apply(to: menu)
    }

    /// Every command with an ID and a title, in menu order, for Settings → Shortcuts.
    /// Hidden commands are listed too: their shortcuts still work (Space 1–9, split panes).
    func entries(in menu: NSMenu) -> [ShortcutEntry] {
        apply(to: menu)
        var seen = Set<String>()
        func walk(_ menu: NSMenu, _ path: [String]) -> [ShortcutEntry] {
            menu.items.flatMap { item -> [ShortcutEntry] in
                if let submenu = item.submenu { return walk(submenu, path + [item.title]) }
                // AppKit names items without an ID after their action ("toggleClaudeSpace:"); Kite's IDs have no colon.
                guard let id = item.identifier?.rawValue, !id.contains(":"), !item.title.isEmpty, item.hasDescribableShortcut,
                      seen.insert(id).inserted
                else { return [] }
                let original = defaults[ObjectIdentifier(item)] ?? item.shortcut
                return [ShortcutEntry(id: id, title: item.title, menuPath: path, shortcut: item.shortcut, defaultShortcut: original)]
            }
        }
        return walk(menu, [])
    }

    /// Called after `apply`, so the Little Kite hotkey can follow its menu item.
    var didApply: (() -> Void)?

    /// Sets every item's key equivalent from its default plus the overrides.
    func apply(to menu: NSMenu?) {
        guard let menu else { return }
        defer { didApply?() }
        // Items whose shortcut KeyShortcut can't describe stay as they are: AppKit's own
        // Emoji & Symbols (fn E) would otherwise lose fn and fire on a bare E while typing.
        let all = Self.items(in: menu)
        let items = all.filter { $0.hasDescribableShortcut && !($0.representedObject is ShortcutMirror) }
        for item in items where defaults[ObjectIdentifier(item)] == nil {
            defaults[ObjectIdentifier(item)] = .some(item.shortcut)
        }
        // Items without an ID still take part, so an override can take their shortcut away.
        var keys: [String: NSMenuItem] = [:]
        var current: [String: KeyShortcut?] = [:]
        for (i, item) in items.enumerated() {
            let key = item.identifier?.rawValue ?? "#\(i)"
            keys[key] = item
            current[key] = .some(defaults[ObjectIdentifier(item)] ?? nil)
        }
        for (key, shortcut) in bindings.resolve(defaults: current) {
            guard let item = keys[key], item.shortcut != shortcut else { continue }
            if let shortcut, !shortcut.isSafeKeyEquivalent {
                NSLog("Kite: ignoring shortcut \(shortcut.displayString) for \(key): it would take keys from typing")
                continue
            }
            item.shortcut = shortcut
        }
        for mirror in all {
            guard let id = (mirror.representedObject as? ShortcutMirror)?.id, let source = keys[id],
                  mirror.shortcut != source.shortcut else { continue }
            mirror.shortcut = source.shortcut
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(bindings).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Kite: couldn't save key bindings: \(error)")
        }
    }

    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            item.submenu.map { items(in: $0) } ?? (item.isSeparatorItem ? [] : [item])
        }
    }
}

/// A second menu item for a command that already has one (Arc's Tabs › New Tab… repeats File › New Tab…).
/// It has no ID of its own, so Settings → Shortcuts and the command bar list the command once, and it
/// always shows the shortcut of the item with `id`.
final class ShortcutMirror: NSObject {
    let id: String
    init(_ id: String) { self.id = id }

    @MainActor static func copy(of item: NSMenuItem, id: String) -> NSMenuItem {
        item.identifier = nil
        item.representedObject = ShortcutMirror(id)
        return item
    }
}

extension NSMenuItem {
    /// False for a key equivalent with modifiers KeyShortcut has no name for, such as fn.
    var hasDescribableShortcut: Bool {
        keyEquivalent.isEmpty
            || keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                .subtracting([.control, .option, .shift, .command]).isEmpty
    }

    /// The key equivalent as a KeyShortcut, and back.
    var shortcut: KeyShortcut? {
        get {
            guard let scalar = keyEquivalent.unicodeScalars.first else { return nil }
            var modifiers = Set<KeyShortcut.Modifier>()
            let mask = keyEquivalentModifierMask
            if mask.contains(.control) { modifiers.insert(.control) }
            if mask.contains(.option) { modifiers.insert(.option) }
            if mask.contains(.shift) { modifiers.insert(.shift) }
            if mask.contains(.command) { modifiers.insert(.command) }
            // AppKit reads an uppercase key equivalent as Shift plus the key.
            if keyEquivalent != keyEquivalent.lowercased() { modifiers.insert(.shift) }
            let key = Self.keyNames[Int(scalar.value)] ?? keyEquivalent.lowercased()
            return KeyShortcut(key, modifiers)
        }
        set {
            guard let newValue else {
                keyEquivalent = ""
                keyEquivalentModifierMask = []
                return
            }
            let code = Self.keyNames.first { $0.value == newValue.key }?.key
            keyEquivalent = code.map { String(Character(UnicodeScalar($0)!)) } ?? newValue.key
            var mask: NSEvent.ModifierFlags = []
            for modifier in newValue.modifiers {
                switch modifier {
                case .control: mask.insert(.control)
                case .option: mask.insert(.option)
                case .shift: mask.insert(.shift)
                case .command: mask.insert(.command)
                }
            }
            keyEquivalentModifierMask = mask
        }
    }

    private static let keyNames: [Int: String] = [
        NSLeftArrowFunctionKey: "left", NSRightArrowFunctionKey: "right",
        NSUpArrowFunctionKey: "up", NSDownArrowFunctionKey: "down",
        0x09: "tab", 0x0D: "return", 0x08: "delete", 0x1B: "escape", 0x20: "space",
    ]
}
