import Foundation

/// A keyboard shortcut, independent of AppKit so it can be stored and tested anywhere.
/// `key` is a menu key equivalent: a lowercased character, or a name from `KeyShortcut.namedKeys`.
public struct KeyShortcut: Codable, Hashable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Comparable, Sendable {
        // Declared in the order macOS draws them: ⌃⌥⇧⌘.
        case control, option, shift, command

        public var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }

        public static func < (a: Self, b: Self) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// Keys with no printable character, by the names stored on disk.
    public static let namedKeys: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        "tab": "⇥", "return": "↩", "delete": "⌫", "escape": "⎋", "space": "Space",
    ]

    public var key: String
    public var modifiers: [Modifier]

    public init(_ key: String, _ modifiers: Set<Modifier>) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers.sorted()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(String.self, forKey: .key), Set(try c.decode([Modifier].self, forKey: .modifiers)))
    }

    /// Whether it can be a menu key equivalent without taking keys a page or text field
    /// needs: it must hold ⌃, ⌥ or ⌘. A bare or ⇧-only key fires instead of typing.
    public var isSafeKeyEquivalent: Bool {
        modifiers.contains { $0 != .shift }
    }

    /// "⇧⌘S", as menus show it.
    public var displayString: String {
        modifiers.map(\.symbol).joined() + (Self.namedKeys[key] ?? key.uppercased())
    }
}

/// Who gets a shortcut first when a web page wants the same keys: Arc's
/// `KeyboardShortcutPriority`, with its raw values, so keybindings.json reads like Arc's
/// StorableKeyBindings.json.
public enum KeyShortcutPriority: String, Codable, CaseIterable, Sendable {
    /// Kite runs the command before the page sees the key.
    case overrideWebView
    /// The page gets the key; if it uses it, pressing the shortcut again runs Kite's command.
    case promptAfterConsumedByWebView
    /// The page gets the key; Kite runs the command only if the page doesn't use it.
    case low

    /// The picker's labels (Arc's, inline literals in its ShortcutsPane PriorityPicker).
    public var title: String {
        switch self {
        case .overrideWebView: "Prefer Kite"
        case .promptAfterConsumedByWebView: "Use Both"
        case .low: "Prefer Websites"
        }
    }

    /// The line under the picker (Arc's strings, "Arc" made "Kite").
    public var subtitle: String {
        switch self {
        case .overrideWebView: "When shortcuts conflict, Kite wins."
        case .promptAfterConsumedByWebView: "Press this shortcut once to use the website’s shortcut. Press it twice to use Kite’s shortcut."
        case .low: "When shortcuts conflict, the website wins."
        }
    }

    /// Each command's priority as Arc's MainMenu.nib sets it (`arcKeyBindingPriority`), by Kite's
    /// IDs. Commands Arc sets nothing for, and Kite's own, are `low`, as Arc's are.
    public static let defaults: [String: KeyShortcutPriority] = {
        let kiteWins = [
            "addressBar", "archiveTab", "closeWindow", "copyCurrentURL", "copyCurrentURLAsQuote",
            "copyCurrentURLAsMarkdown", "nextRecentTabItem", "goBack", "goForward", "hideKite", "minimize",
            "newIncognitoWindow", "newTab", "newWindow", "quitKite", "reopenClosedTab", "nextTab", "previousTab",
            "newLittleBrowserWindow",
        ]
        let both = [
            "addSplitView", "developerTools", "fullscreen", "inspectElements", "pinTab", "printPage",
            "removeSplitView", "toggleSidebar", "toggleDeveloperMode", "toggleToolbar", "viewSource",
        ]
        var table: [String: KeyShortcutPriority] = [:]
        for id in kiteWins { table[id] = .overrideWebView }
        for id in both { table[id] = .promptAfterConsumedByWebView }
        return table
    }()

    public static func defaultPriority(for action: String) -> KeyShortcutPriority {
        defaults[action] ?? .low
    }
}

/// A user's change to one command's shortcut. `shortcut == nil` removes it.
public struct KeyBindingOverride: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case user
        /// Brought over from Arc's StorableKeyBindings.json.
        case arc
    }

    /// The menu command's stable ID, lowerCamel like Arc's (`copyCurrentURL`, `nextSpace`).
    public var action: String
    public var shortcut: KeyShortcut?
    public var source: Source
    /// Who wins when a page wants the same keys; nil keeps the command's default.
    public var priority: KeyShortcutPriority?

    public init(action: String, shortcut: KeyShortcut?, source: Source = .user, priority: KeyShortcutPriority? = nil) {
        self.action = action
        self.shortcut = shortcut
        self.source = source
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey { case action, shortcut, source, priority }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        shortcut = try c.decodeIfPresent(KeyShortcut.self, forKey: .shortcut)
        source = try c.decode(Source.self, forKey: .source)
        // Files from before priorities have none; a value this build doesn't know keeps the default.
        priority = (try? c.decodeIfPresent(KeyShortcutPriority.self, forKey: .priority)) ?? nil
    }
}

/// Shortcut overrides on disk (keybindings.json), laid out like Arc's
/// StorableKeyBindings.json so Arc's remaps map across one to one.
public struct KeyBindings: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = Self.currentVersion
    public private(set) var userOverrides: [KeyBindingOverride] = []

    public init(userOverrides: [KeyBindingOverride] = []) {
        userOverrides.forEach { set($0) }
    }

    public func override(for action: String) -> KeyBindingOverride? {
        userOverrides.first { $0.action == action }
    }

    /// One override per action; a later one replaces an earlier one.
    public mutating func set(_ override: KeyBindingOverride) {
        userOverrides.removeAll { $0.action == override.action }
        userOverrides.append(override)
    }

    /// Changes a command's shortcut, keeping any priority the user chose for it.
    public mutating func setShortcut(_ shortcut: KeyShortcut?, for action: String, source: KeyBindingOverride.Source = .user) {
        set(KeyBindingOverride(action: action, shortcut: shortcut, source: source, priority: override(for: action)?.priority))
    }

    /// Changes a command's priority. `shortcut` is the one it has now, which the override keeps,
    /// as Arc's does (an Arc override always holds the shortcut along with the priority).
    public mutating func setPriority(_ priority: KeyShortcutPriority, for action: String, shortcut: KeyShortcut?) {
        let existing = override(for: action)
        let keep = priority == KeyShortcutPriority.defaultPriority(for: action) ? nil : priority
        set(KeyBindingOverride(action: action, shortcut: existing?.shortcut ?? shortcut, source: existing?.source ?? .user, priority: keep))
    }

    /// The command's priority: the user's, else its default.
    public func priority(for action: String) -> KeyShortcutPriority {
        override(for: action)?.priority ?? KeyShortcutPriority.defaultPriority(for: action)
    }

    public mutating func reset(_ action: String) {
        userOverrides.removeAll { $0.action == action }
    }

    /// What each command's shortcut becomes, given its defaults. An overridden
    /// shortcut is taken away from any other command that had it, as in Arc.
    public func resolve(defaults: [String: KeyShortcut?]) -> [String: KeyShortcut?] {
        var result = defaults
        for override in userOverrides where defaults.keys.contains(override.action) {
            if let shortcut = override.shortcut {
                for (action, current) in result where current == shortcut && action != override.action {
                    result[action] = .some(nil)
                }
            }
            result[override.action] = .some(override.shortcut)
        }
        return result
    }
}
