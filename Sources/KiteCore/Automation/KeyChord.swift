import Foundation

/// A key press like "Enter", "cmd+a" or "shift+Tab", resolved to what the
/// DevTools protocol's `Input.dispatchKeyEvent` needs.
public struct KeyChord: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        // CDP's bit values.
        public static let alt = Modifiers(rawValue: 1)
        public static let control = Modifiers(rawValue: 2)
        public static let meta = Modifiers(rawValue: 4)
        public static let shift = Modifiers(rawValue: 8)
    }

    /// DOM `key`, e.g. "Enter", "a", "ArrowLeft".
    public var key: String
    /// DOM `code`, e.g. "Enter", "KeyA".
    public var code: String
    /// Windows virtual key code, which Chromium uses to route the key.
    public var keyCode: Int
    /// Text the key types, if any (none when a command modifier is held).
    public var text: String?
    public var modifiers: Modifiers
    /// macOS editing commands (selectAll, copy, …): Chromium on the Mac only acts on
    /// ⌘ shortcuts sent through the protocol when they name the command.
    public var commands: [String]

    public init(key: String, code: String, keyCode: Int, text: String?, modifiers: Modifiers, commands: [String]) {
        self.key = key
        self.code = code
        self.keyCode = keyCode
        self.text = text
        self.modifiers = modifiers
        self.commands = commands
    }

    public var isEnter: Bool { key == "Enter" }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    private struct Named {
        var key: String
        var code: String
        var keyCode: Int
        var text: String?
    }

    private static let named: [String: Named] = {
        var table: [String: Named] = [
            "enter": Named(key: "Enter", code: "Enter", keyCode: 13, text: "\r"),
            "tab": Named(key: "Tab", code: "Tab", keyCode: 9, text: nil),
            "escape": Named(key: "Escape", code: "Escape", keyCode: 27, text: nil),
            "backspace": Named(key: "Backspace", code: "Backspace", keyCode: 8, text: nil),
            "delete": Named(key: "Delete", code: "Delete", keyCode: 46, text: nil),
            "space": Named(key: " ", code: "Space", keyCode: 32, text: " "),
            "arrowup": Named(key: "ArrowUp", code: "ArrowUp", keyCode: 38, text: nil),
            "arrowdown": Named(key: "ArrowDown", code: "ArrowDown", keyCode: 40, text: nil),
            "arrowleft": Named(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37, text: nil),
            "arrowright": Named(key: "ArrowRight", code: "ArrowRight", keyCode: 39, text: nil),
            "home": Named(key: "Home", code: "Home", keyCode: 36, text: nil),
            "end": Named(key: "End", code: "End", keyCode: 35, text: nil),
            "pageup": Named(key: "PageUp", code: "PageUp", keyCode: 33, text: nil),
            "pagedown": Named(key: "PageDown", code: "PageDown", keyCode: 34, text: nil),
        ]
        for n in 1...12 { table["f\(n)"] = Named(key: "F\(n)", code: "F\(n)", keyCode: 111 + n, text: nil) }
        let aliases = ["return": "enter", "esc": "escape", "up": "arrowup", "down": "arrowdown", "left": "arrowleft",
                       "right": "arrowright", "del": "delete", "pgup": "pageup", "pgdn": "pagedown", "spacebar": "space"]
        for (alias, name) in aliases { table[alias] = table[name] }
        return table
    }()

    /// Punctuation on a US layout: character → (code, keyCode).
    private static let punctuation: [Character: (String, Int)] = [
        "-": ("Minus", 189), "=": ("Equal", 187), "[": ("BracketLeft", 219), "]": ("BracketRight", 221),
        "\\": ("Backslash", 220), ";": ("Semicolon", 186), "'": ("Quote", 222), ",": ("Comma", 188),
        ".": ("Period", 190), "/": ("Slash", 191), "`": ("Backquote", 192),
    ]

    /// ⌘ shortcuts that need their editing command named on the Mac.
    private static let macCommands: [String: String] = [
        "a": "selectAll", "c": "copy", "x": "cut", "v": "paste", "z": "undo",
    ]

    /// Parses one chord: modifiers and a key joined by "+", e.g. "cmd+shift+z".
    public static func parse(_ text: String) throws -> KeyChord {
        if text == "+" { return try single("+", modifiers: []) }
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" means cmd and the + key.
        var tokens = parts
        if text.hasSuffix("++") { tokens = Array(parts.dropLast(2)) + ["+"] }
        guard let last = tokens.last, !last.isEmpty else { throw ParseError(description: "\"\(text)\" names no key.") }

        var modifiers: Modifiers = []
        for token in tokens.dropLast() {
            switch token.lowercased() {
            case "cmd", "command", "meta", "super", "win": modifiers.insert(.meta)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option", "opt": modifiers.insert(.alt)
            case "shift": modifiers.insert(.shift)
            default: throw ParseError(description: "\"\(token)\" isn't a modifier (use cmd, ctrl, alt or shift).")
            }
        }

        var chord: KeyChord
        if let named = named[last.lowercased()] {
            chord = KeyChord(key: named.key, code: named.code, keyCode: named.keyCode, text: named.text,
                             modifiers: modifiers, commands: [])
        } else if last.count == 1, let character = last.first {
            chord = try single(character, modifiers: modifiers)
        } else {
            throw ParseError(description: "\"\(last)\" isn't a key name.")
        }
        if !chord.modifiers.isDisjoint(with: [.meta, .control, .alt]) && chord.key.count == 1 { chord.text = nil }
        if chord.modifiers == .meta, let command = macCommands[chord.key.lowercased()] { chord.commands = [command] }
        if chord.modifiers == [.meta, .shift], chord.key.lowercased() == "z" { chord.commands = ["redo"] }
        return chord
    }

    /// Space-separated chords, e.g. "cmd+a Backspace".
    public static func parseSequence(_ text: String) throws -> [KeyChord] {
        let chords = try text.split(separator: " ").map { try parse(String($0)) }
        guard !chords.isEmpty else { throw ParseError(description: "No keys given.") }
        return chords
    }

    private static func single(_ character: Character, modifiers: Modifiers) throws -> KeyChord {
        var modifiers = modifiers
        if character.isLetter, character.isASCII {
            let lower = Character(character.lowercased())
            if character.isUppercase { modifiers.insert(.shift) }
            let shifted = modifiers.contains(.shift)
            let key = shifted ? String(lower).uppercased() : String(lower)
            return KeyChord(key: key, code: "Key\(String(lower).uppercased())",
                            keyCode: Int(lower.asciiValue! - 97 + 65), text: key, modifiers: modifiers, commands: [])
        }
        if character.isNumber, character.isASCII {
            return KeyChord(key: String(character), code: "Digit\(character)", keyCode: Int(character.asciiValue!),
                            text: String(character), modifiers: modifiers, commands: [])
        }
        if let (code, keyCode) = punctuation[character] {
            return KeyChord(key: String(character), code: code, keyCode: keyCode, text: String(character),
                            modifiers: modifiers, commands: [])
        }
        // Anything else is typed as text with no physical key.
        return KeyChord(key: String(character), code: "", keyCode: 0, text: String(character), modifiers: modifiers, commands: [])
    }
}
