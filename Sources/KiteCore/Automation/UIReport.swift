import Foundation

/// One view, layer or accessibility element in a Kite window, as the `ui` tool reports it.
public struct UINode: Hashable, Sendable {
    public struct Attribute: Hashable, Sendable {
        public var name: String
        public var value: String
        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    /// Class name for views and layers, role for accessibility elements ("AXButton").
    public var kind: String
    public var identifier: String?
    /// Visible text or accessibility label. Tab titles come from web pages, so the
    /// report wraps the whole tree as untrusted content.
    public var label: String?
    public var frame: UIRect?
    public var attributes: [Attribute]
    public var children: [UINode]

    public init(kind: String, identifier: String? = nil, label: String? = nil, frame: UIRect? = nil,
                attributes: [Attribute] = [], children: [UINode] = []) {
        self.kind = kind
        self.identifier = identifier
        self.label = label
        self.frame = frame
        self.attributes = attributes
        self.children = children
    }

    /// The node at a path relative to this one: "0" is this node, "0.2" its third child.
    public func node(at path: String) -> UINode? {
        let parts = path.split(separator: ".").map { Int($0) }
        guard parts.first == 0, parts.allSatisfy({ $0 != nil }) else { return nil }
        var node = self
        for index in parts.dropFirst().map({ $0! }) {
            guard node.children.indices.contains(index) else { return nil }
            node = node.children[index]
        }
        return node
    }

    /// This node and everything under it.
    var count: Int { children.reduce(1) { $0 + $1.count } }

    func matches(_ query: String) -> Bool {
        [kind, identifier, label].compactMap { $0 }.contains { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    var line: String {
        var parts = [kind]
        if let identifier, !identifier.isEmpty { parts.append("#" + identifier) }
        if let label, !label.isEmpty { parts.append(AccessibilityOutline.quote(AccessibilityOutline.clean(label, limit: 80))) }
        if let frame { parts.append("[\(frame.description)]") }
        parts += attributes.map { "\($0.name)=\($0.value)" }
        return parts.joined(separator: " ")
    }
}

/// A menu bar item, for `ui menu`.
public struct UIMenuItem: Hashable, Sendable {
    public var path: [String]
    /// The key equivalent as AppKit holds it ("t", "\u{F702}" for ←), empty for none.
    public var key: String
    /// Any of cmd, ctrl, alt, shift, fn.
    public var modifiers: Set<String>
    public var action: String?
    public var target: String?
    public var identifier: String?
    public var isEnabled: Bool
    public var isHidden: Bool
    public var isOn: Bool

    public init(path: [String], key: String, modifiers: Set<String>, action: String?, target: String?, identifier: String?,
                isEnabled: Bool, isHidden: Bool, isOn: Bool) {
        self.path = path
        self.key = key
        self.modifiers = modifiers
        self.action = action
        self.target = target
        self.identifier = identifier
        self.isEnabled = isEnabled
        self.isHidden = isHidden
        self.isOn = isOn
    }

    /// "⌃⌥⇧⌘K", in the menu bar's order.
    public var shortcut: String {
        guard !key.isEmpty else { return "" }
        let symbols: [(String, String)] = [("fn", "fn "), ("ctrl", "⌃"), ("alt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + Self.keyName(key)
    }

    /// A shortcut that fires while typing: a printable key with no ⌘, ⌃ or ⌥. AppKit ignores fn when it
    /// matches a key against the menu bar, so fn E fires on a plain "e" too. (Pages send unhandled keys to
    /// the menu bar, so these steal plain typing.) Keys no keyboard types, like the dictation key's 🎤, don't count.
    public var firesWhileTyping: Bool {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return false }
        let isFunctionKey = (0xF700...0xF8FF).contains(scalar.value)
        let isControl = scalar.value < 0x20 || scalar.value == 0x7F
        let isTyped = scalar.value <= 0xFFFF
        return modifiers.isDisjoint(with: ["cmd", "ctrl", "alt"]) && !isFunctionKey && !isControl && isTyped
    }

    public static func keyName(_ key: String) -> String {
        let names: [UInt32: String] = [
            0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→", 0x0D: "↩", 0x03: "⌤", 0x09: "⇥", 0x1B: "⎋", 0x08: "⌫",
            0x7F: "⌫", 0xF728: "⌦", 0x20: "Space", 0xF729: "↖", 0xF72B: "↘", 0xF72C: "⇞", 0xF72D: "⇟",
        ]
        guard let scalar = key.unicodeScalars.first else { return key }
        if let name = names[scalar.value] { return name }
        if (0xF704...0xF71B).contains(scalar.value) { return "F\(scalar.value - 0xF704 + 1)" }
        return key.uppercased()
    }
}

/// What one synthetic pointer position found, for `ui pointer`.
public struct UIPointerSample: Hashable, Sendable {
    public var point: UIPoint
    /// Path and class of the deepest view hit, nil outside the window's views.
    public var hit: String?
    /// Cursor rects containing the point: "SidebarResizeHandle resizeLeftRight [x,y w×h]".
    public var cursorRects: [String]
    /// Tracking areas containing the point: "NSHostingView enteredExited,cursorUpdate [x,y w×h]".
    public var trackingAreas: [String]
    /// The cursor Kite showed after the move, by name ("arrow", "resizeLeftRight") or "custom(…)".
    public var cursor: String

    public init(point: UIPoint, hit: String?, cursorRects: [String], trackingAreas: [String], cursor: String) {
        self.point = point
        self.hit = hit
        self.cursorRects = cursorRects
        self.trackingAreas = trackingAreas
        self.cursor = cursor
    }

    var summary: String {
        var parts = ["cursor \(cursor)", "hit \(hit ?? "nothing")"]
        if !cursorRects.isEmpty { parts.append("cursor rects: " + cursorRects.joined(separator: "; ")) }
        if !trackingAreas.isEmpty { parts.append("tracking: " + trackingAreas.joined(separator: "; ")) }
        return parts.joined(separator: " | ")
    }
}

/// Formats the `ui` tool's answers. Compact by default: frames on one line per node, and
/// identical pointer samples folded into runs.
public enum UIReport {
    /// Up to two decimals, no trailing zeros: 240, 12.5, 0.33.
    public static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.2f", rounded).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    /// The tree under `root` (whose path is `rootPath`), indented, at most `depth` levels and `maxNodes` lines.
    /// With `match`, only matching nodes, flat, each with its path.
    public static func tree(_ root: UINode, rootPath: String = "0", depth: Int, match: String?, maxNodes: Int,
                            source: String = "Kite window") -> String {
        var lines: [String] = []
        var omitted = 0

        func visit(_ node: UINode, path: String, level: Int) {
            if let match {
                if node.matches(match) {
                    if lines.count < maxNodes { lines.append("\(path) \(node.line)") } else { omitted += 1 }
                }
            } else {
                guard lines.count < maxNodes else {
                    omitted += node.count
                    return
                }
                lines.append(String(repeating: "  ", count: level) + "\(path) \(node.line)")
                if level + 1 >= depth, !node.children.isEmpty {
                    lines.append(String(repeating: "  ", count: level + 1) + "… \(node.children.count) children (root \(path) to see them)")
                    return
                }
            }
            for (index, child) in node.children.enumerated() { visit(child, path: "\(path).\(index)", level: level + 1) }
        }
        visit(root, path: rootPath, level: 0)
        if lines.isEmpty { return match.map { "Nothing matches \"\($0)\"." } ?? "Empty." }
        if omitted > 0 { lines.append("… \(omitted) more nodes (raise max_nodes, or use root or match)") }
        return UntrustedContent.wrap(lines.joined(separator: "\n"), source: source)
    }

    public static func menu(_ items: [UIMenuItem], match: String?) -> String {
        let shown = items.filter { item in
            guard let match else { return true }
            return ([item.path.joined(separator: " > "), item.shortcut, item.action ?? "", item.identifier ?? ""])
                .contains { $0.range(of: match, options: .caseInsensitive) != nil }
        }
        var lines = shown.map { item -> String in
            var parts = [item.path.joined(separator: " > ")]
            if !item.shortcut.isEmpty { parts.append(item.shortcut) }
            if let action = item.action { parts.append(action + (item.target.map { " → \($0)" } ?? " → responder chain")) }
            if let identifier = item.identifier { parts.append("#\(identifier)") }
            var flags: [String] = []
            if !item.isEnabled { flags.append("disabled") }
            if item.isHidden { flags.append("hidden") }
            if item.isOn { flags.append("on") }
            if item.firesWhileTyping { flags.append("FIRES WHILE TYPING") }
            if !flags.isEmpty { parts.append("(\(flags.joined(separator: ", ")))") }
            return parts.joined(separator: "  ")
        }
        // Two enabled items on one shortcut: only the first in menu order ever fires.
        var seen: [String: String] = [:]
        for item in items where !item.shortcut.isEmpty && item.isEnabled {
            let name = item.path.joined(separator: " > ")
            if let first = seen[item.shortcut] {
                lines.append("CONFLICT \(item.shortcut): \(first) wins over \(name)")
            } else {
                seen[item.shortcut] = name
            }
        }
        if lines.isEmpty { return match.map { "No menu item matches \"\($0)\"." } ?? "The menu bar is empty." }
        return lines.joined(separator: "\n")
    }

    /// Pointer samples, consecutive identical results folded into one run.
    public static func pointer(_ samples: [UIPointerSample]) -> String {
        var lines: [String] = []
        var start = 0
        for index in samples.indices {
            let isLast = index == samples.count - 1
            if isLast || samples[index + 1].summary != samples[start].summary {
                let from = samples[start].point, to = samples[index].point
                let at = start == index ? "(\(number(from.x)), \(number(from.y)))"
                    : "(\(number(from.x)), \(number(from.y))) → (\(number(to.x)), \(number(to.y))), \(index - start + 1) points"
                lines.append("\(at): \(samples[start].summary)")
                start = index + 1
            }
        }
        return lines.joined(separator: "\n")
    }
}
