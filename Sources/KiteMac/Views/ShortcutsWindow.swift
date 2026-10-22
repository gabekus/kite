import AppKit

/// Help → Keyboard Shortcuts: every menu command that has a shortcut, read from
/// the menu bar itself so it can't drift from the real bindings.
@MainActor
enum ShortcutsWindow {
    private static var panel: NSPanel?

    static func show(for menu: NSMenu?) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if let textView = (panel.contentView as? NSScrollView)?.documentView as? NSTextView {
            textView.textStorage?.setAttributedString(listing(menu))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = "Keyboard Shortcuts"
        panel.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.textContainerInset = NSSize(width: 16, height: 14)
            textView.drawsBackground = false
        }
        panel.contentView = scroll
        panel.center()
        return panel
    }

    private static func listing(_ menu: NSMenu?) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 400)]
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for top in menu?.items ?? [] {
            guard let submenu = top.submenu else { continue }
            let rows = shortcuts(in: submenu)
            guard !rows.isEmpty else { continue }
            output.append(NSAttributedString(string: (output.length == 0 ? "" : "\n") + top.title + "\n", attributes: heading))
            for (title, keys) in rows {
                output.append(NSAttributedString(string: "\(title)\t\(keys)\n", attributes: body))
            }
        }
        return output
    }

    private static func shortcuts(in menu: NSMenu) -> [(String, String)] {
        menu.items.flatMap { item -> [(String, String)] in
            if let submenu = item.submenu { return shortcuts(in: submenu) }
            guard !item.isHidden, !item.keyEquivalent.isEmpty else { return [] }
            return [(item.title, describe(item.keyEquivalent, item.keyEquivalentModifierMask))]
        }
    }

    static func describe(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) || key != key.lowercased() { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let names: [Character: String] = [
            Character(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
            Character(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
            Character(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
            Character(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            "\t": "⇥", "\r": "↩", " ": "Space",
        ]
        return text + (key.first.flatMap { names[$0] } ?? key.uppercased())
    }
}
