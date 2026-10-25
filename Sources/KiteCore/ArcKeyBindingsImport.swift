import Foundation

/// The user's shortcut changes in Arc (StorableKeyBindings.json), as Kite overrides.
/// Delete with ArcImport.swift once Arc has shut down.
public enum ArcKeyBindingsImport {
    /// Arc action IDs whose Kite command has another name. The rest share Arc's ID,
    /// so an override for a command Kite doesn't have yet (addSplitView) applies once it lands.
    static let kiteActions = [
        "addressBar": "openLocation",
        "focusNextSpace": "nextSpace",
        "focusPreviousSpace": "previousSpace",
    ]

    // NSEvent.ModifierFlags raw values; Foundation-only, so not the AppKit type.
    private static let modifierBits: [(Int, KeyShortcut.Modifier)] = [
        (1 << 17, .shift), (1 << 18, .control), (1 << 19, .option), (1 << 20, .command),
    ]

    private static let arrows = ["←": "left", "→": "right", "↑": "up", "↓": "down"]
    // Arc may also store an arrow as the AppKit function-key character.
    private static let functionKeys: [UInt32: String] = [0xF702: "left", 0xF703: "right", 0xF700: "up", 0xF701: "down"]

    private struct File: Decodable {
        var userOverrides: [Override]
    }

    private struct Override: Decodable {
        var action: Action
        var state: [String: [String: Shortcut]]
        struct Action: Decodable { var identifier: String }
    }

    struct Shortcut: Decodable {
        var keyEquivalent: String
        var deviceIndependentModifierFlags: Int
    }

    /// One override per changed action. Arc's `unset` state means the user removed
    /// the shortcut; `valid` holds the new one. Entries Kite can't read are skipped.
    public static func parse(_ data: Data) throws -> [KeyBindingOverride] {
        try JSONDecoder().decode(File.self, from: data).userOverrides.compactMap { entry in
            let action = kiteActions[entry.action.identifier] ?? entry.action.identifier
            if entry.state["unset"] != nil {
                return KeyBindingOverride(action: action, shortcut: nil, source: .arc)
            }
            guard let arc = entry.state["valid"]?["_0"], let shortcut = shortcut(arc) else { return nil }
            return KeyBindingOverride(action: action, shortcut: shortcut, source: .arc)
        }
    }

    static func shortcut(_ arc: Shortcut) -> KeyShortcut? {
        guard let scalar = arc.keyEquivalent.unicodeScalars.first, arc.keyEquivalent.unicodeScalars.count == 1 else { return nil }
        let key = arrows[arc.keyEquivalent] ?? functionKeys[scalar.value] ?? arc.keyEquivalent
        let modifiers = Set(modifierBits.filter { arc.deviceIndependentModifierFlags & $0.0 != 0 }.map(\.1))
        // fn (1 << 23) has no Kite modifier. Dropping it would leave a bare key that fires while typing.
        if arc.deviceIndependentModifierFlags & 1 << 23 != 0, arrows[arc.keyEquivalent] == nil, functionKeys[scalar.value] == nil {
            return nil
        }
        let shortcut = KeyShortcut(key, modifiers)
        return shortcut.isSafeKeyEquivalent ? shortcut : nil
    }
}
