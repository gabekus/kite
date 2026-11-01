import AppKit
import KiteCore

/// Marks a menu item the command bar offers even while it's hidden from the menu bar, with extra words
/// it also matches by (Arc's type-travel keywords; may be empty).
final class CommandBarKeywords: NSObject {
    let words: [String]
    init(_ words: [String]) { self.words = words }
}

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

    /// Commands matching `query`, best first. Only enabled, visible commands, as the menu would show them,
    /// plus hidden ones carrying `CommandBarKeywords` (MainMenu's `commandBarOnly`).
    @MainActor
    static func search(_ query: String, in menu: NSMenu?, limit: Int = 3) -> [(command: MenuCommand, score: Int)] {
        var results: [(MenuCommand, Int)] = []
        func walk(_ menu: NSMenu, path: [String]) {
            menu.update()
            for item in menu.items where !item.isSeparatorItem {
                let keywords = item.representedObject as? CommandBarKeywords
                if item.isHidden && keywords == nil { continue }
                // A repeat of a command listed elsewhere in the menu bar (Tabs › New Tab…).
                if item.representedObject is ShortcutMirror { continue }
                if let submenu = item.submenu {
                    walk(submenu, path: path + [item.title])
                } else if item.action != nil, item.isEnabled, !item.title.isEmpty,
                          // AppKit's window list in the Window menu: titled after pages, not commands.
                          item.action != #selector(NSWindow.makeKeyAndOrderFront(_:)),
                          !(item.target is NSWindow), !(item.representedObject is NSWindow),
                          let score = ([item.title] + (keywords?.words ?? [])).compactMap({ CommandSearch.score(query, title: $0) }).max() {
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
