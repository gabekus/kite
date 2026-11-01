import AppKit
import KiteCore

/// A menu bar command offered in the command bar (Arc lets you run any action from there).
struct MenuCommand: Hashable {
    let item: NSMenuItem
    /// Where it lives, e.g. "View › Developer".
    let path: String

    var title: String { item.title }
    @MainActor
    var shortcut: String? {
        item.keyEquivalent.isEmpty ? nil : ShortcutsWindow.describe(item.keyEquivalent, item.keyEquivalentModifierMask)
    }

    /// Marks a hidden menu item that the command bar still offers (`representedObject`).
    static let commandBarOnly = "kite.commandBarOnly"

    /// Commands matching `query`, best first. Only enabled, visible commands, as the menu would show them,
    /// plus hidden ones marked `commandBarOnly`.
    @MainActor
    static func search(_ query: String, in menu: NSMenu?, limit: Int = 3) -> [(command: MenuCommand, score: Int)] {
        var results: [(MenuCommand, Int)] = []
        func walk(_ menu: NSMenu, path: [String]) {
            menu.update()
            for item in menu.items where (!item.isHidden || item.representedObject as? String == commandBarOnly) && !item.isSeparatorItem {
                if let submenu = item.submenu {
                    walk(submenu, path: path + [item.title])
                } else if item.action != nil, item.isEnabled, !item.title.isEmpty,
                          // AppKit's window list in the Window menu: titled after pages, not commands.
                          item.action != #selector(NSWindow.makeKeyAndOrderFront(_:)),
                          !(item.target is NSWindow), !(item.representedObject is NSWindow),
                          let score = CommandSearch.score(query, title: item.title) {
                    results.append((MenuCommand(item: item, path: path.joined(separator: " › ")), score))
                }
            }
        }
        // Skip the Kite menu: Hide, Quit and Services aren't worth a result.
        for top in menu?.items.dropFirst() ?? [] {
            if let submenu = top.submenu { walk(submenu, path: [top.title]) }
        }
        return Array(results.sorted { $0.1 > $1.1 }.prefix(limit)).map { (command: $0.0, score: $0.1) }
    }

    /// Runs it the way the menu would.
    @MainActor
    func perform() {
        NSApp.sendAction(item.action!, to: item.target, from: item)
    }
}
