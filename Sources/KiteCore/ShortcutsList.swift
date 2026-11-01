import Foundation

/// One command in Settings → Shortcuts: a menu item with an ID, its shortcut now and as built.
public struct ShortcutEntry: Hashable, Sendable, Identifiable {
    /// The menu item's ID, the key in keybindings.json.
    public var id: String
    public var title: String
    /// The menus it sits in, top first ("View", "Developer").
    public var menuPath: [String]
    public var shortcut: KeyShortcut?
    public var defaultShortcut: KeyShortcut?
    /// Who wins when a page wants the same keys.
    public var priority: KeyShortcutPriority

    public init(id: String, title: String, menuPath: [String] = [], shortcut: KeyShortcut?, defaultShortcut: KeyShortcut?,
                priority: KeyShortcutPriority? = nil) {
        self.id = id
        self.title = title
        self.menuPath = menuPath
        self.shortcut = shortcut
        self.defaultShortcut = defaultShortcut
        self.priority = priority ?? KeyShortcutPriority.defaultPriority(for: id)
    }

    public var isCustomized: Bool { shortcut != defaultShortcut || priority != KeyShortcutPriority.defaultPriority(for: id) }
}

/// The Shortcuts pane's list logic, kept out of AppKit so it can be tested.
public enum ShortcutsList {
    /// The other commands that already use `shortcut`.
    public static func conflicts(for shortcut: KeyShortcut?, excluding id: String, in entries: [ShortcutEntry]) -> [ShortcutEntry] {
        guard let shortcut else { return [] }
        return entries.filter { $0.id != id && $0.shortcut == shortcut }
    }

    /// Arc's conflict note: `“Title”`, `“Title” and one other action`, `“Title” and 2 other actions`,
    /// after "⌘L is already in use by ".
    public static func conflictDescription(_ conflicts: [ShortcutEntry]) -> String? {
        guard let first = conflicts.first else { return nil }
        switch conflicts.count {
        case 1: return "is already in use by “\(first.title)”"
        case 2: return "is already in use by “\(first.title)” and one other action"
        default: return "is already in use by “\(first.title)” and \(conflicts.count - 1) other actions"
        }
    }

    /// Customized commands first, then the rest, each in menu order, filtered by the search field.
    public static func sections(_ entries: [ShortcutEntry], query: String) -> (customized: [ShortcutEntry], defaults: [ShortcutEntry]) {
        let shown = entries.filter { matches($0, query: query) }
        return (shown.filter(\.isCustomized), shown.filter { !$0.isCustomized })
    }

    /// The search field takes a command's name or a shortcut, typed as symbols ("⌘E")
    /// or words ("Command E", "cmd shift e").
    public static func matches(_ entry: ShortcutEntry, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let haystack = ([entry.title] + entry.menuPath).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if haystack.contains(folded) { return true }
        guard let shortcut = entry.shortcut, let wanted = parseShortcut(trimmed) else { return false }
        if let key = wanted.key, key != shortcut.key { return false }
        return wanted.modifiers.isSubset(of: Set(shortcut.modifiers)) && (wanted.key != nil || !wanted.modifiers.isEmpty)
    }

    private static let modifierWords: [String: KeyShortcut.Modifier] = [
        "command": .command, "cmd": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "control": .control, "ctrl": .control, "⌃": .control,
    ]

    /// Reads "Command E", "cmd+shift+e" or "⇧⌘E". A query with any word that isn't a modifier
    /// or a single key isn't a shortcut. `key` is nil when only modifiers were typed.
    static func parseShortcut(_ text: String) -> (key: String?, modifiers: Set<KeyShortcut.Modifier>)? {
        // Split symbols off so "⇧⌘E" reads as three tokens.
        var spaced = ""
        for ch in text.lowercased() {
            // "+" joins keys ("cmd+e"); "-" is a key of its own (Zoom Out).
            if "⌘⇧⌥⌃".contains(ch) { spaced += " \(ch) " } else if ch == "+" && text.count > 1 { spaced += " " } else { spaced.append(ch) }
        }
        var modifiers = Set<KeyShortcut.Modifier>()
        var key: String?
        for token in spaced.split(separator: " ").map(String.init) {
            if let modifier = modifierWords[token] {
                modifiers.insert(modifier)
            } else if key == nil, token.count == 1 || KeyShortcut.namedKeys[token] != nil {
                key = token
            } else if key == nil, let named = KeyShortcut.namedKeys.first(where: { $0.value.lowercased() == token })?.key {
                key = named
            } else {
                return nil
            }
        }
        // A lone letter is a search for names, not a shortcut.
        return modifiers.isEmpty ? nil : (key, modifiers)
    }
}
