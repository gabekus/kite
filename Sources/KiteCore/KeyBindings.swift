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

    public init(action: String, shortcut: KeyShortcut?, source: Source = .user) {
        self.action = action
        self.shortcut = shortcut
        self.source = source
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
