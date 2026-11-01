import AppKit
import KiteCore

/// Arc's link items of the page's right-click menu, shared by both engines: WebKit adds them as
/// AppKit menu items, Chromium as CEF menu entries (KCBrowser asks ChromiumPage for them).
@MainActor
enum PageContextMenuItems {
    /// Runs `item` for `url`: copies the address itself, or hands the rest to the page's owner.
    static func perform(_ item: PageContextMenu.Item, url: URL, send: (PageEvent) -> Void, download: (URL) -> Void) {
        switch item {
        case .open(let target):
            send(.openLink(url, target))
        case .saveLinkAs:
            download(url)
        case .copyLinkAddress, .copyEmailAddress:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let text = PageContextMenu.copiedText(for: item, url: url)
            pasteboard.setString(text, forType: .string)
            if item == .copyLinkAddress { pasteboard.setString(text, forType: .URL) }
        case .separator:
            break
        }
    }

    /// AppKit menu items for the link section, each running `perform` when chosen.
    static func menuItems(for url: URL, host: PageContextMenu.Host,
                          perform: @escaping (PageContextMenu.Item) -> Void) -> [NSMenuItem] {
        PageContextMenu.linkItems(for: url, host: host).map { item in
            guard item != .separator else { return .separator() }
            return action(PageContextMenu.title(item), enabled: PageContextMenu.isEnabled(item, host: host)) { perform(item) }
        }
    }

    /// A menu item that runs `body`. The item keeps its target alive (menu item targets are weak), and
    /// the target answers menu validation, so `enabled` holds in a menu that enables its own items.
    static func action(_ title: String, enabled: Bool = true, _ body: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(enabled: enabled, body)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.isEnabled = enabled
        return item
    }

    /// Drops separators at either end and runs of them in between.
    static func tidySeparators(_ items: [NSMenuItem]) -> [NSMenuItem] {
        var result: [NSMenuItem] = []
        for item in items {
            if item.isSeparatorItem && (result.last?.isSeparatorItem ?? true) { continue }
            result.append(item)
        }
        while result.last?.isSeparatorItem == true { result.removeLast() }
        return result
    }

    // MARK: Test hook

    /// `KITE_TEST_CONTEXT_MENU`, on a throwaway profile only: a right-click logs the menu it built
    /// (stderr, "KITE_TEST_CONTEXT_MENU: …") instead of showing it, since a context menu is modal
    /// and can't be read from the background. A value other than 1 is an item title to choose, as
    /// is the text of `test-context-menu-pick` in the profile folder when that file exists.
    static var testMode: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KITE_SUPPORT_PATH"]?.isEmpty == false,
              let value = environment["KITE_TEST_CONTEXT_MENU"], !value.isEmpty else { return nil }
        return value
    }

    /// Logs `entries` (title, enabled; nil title for a separator) and picks the one the test asked
    /// for. Returns that entry's index, or nil.
    static func logForTest(_ entries: [(title: String?, enabled: Bool)]) -> Int? {
        guard let mode = testMode else { return nil }
        let line = entries.map { entry in
            guard let title = entry.title else { return "---" }
            return entry.enabled ? title : "(\(title))"
        }.joined(separator: " | ")
        FileHandle.standardError.write(Data("KITE_TEST_CONTEXT_MENU: \(line)\n".utf8))
        let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] ?? "")
            .appendingPathComponent("test-context-menu-pick")
        let pick = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (mode == "1" ? nil : mode)
        guard let pick, !pick.isEmpty else { return nil }
        return entries.firstIndex { $0.title == pick && $0.enabled }
    }
}

private final class MenuAction: NSObject, NSMenuItemValidation {
    private let enabled: Bool
    private let body: () -> Void
    init(enabled: Bool, _ body: @escaping () -> Void) {
        self.enabled = enabled
        self.body = body
    }
    @objc func run(_ sender: Any?) { body() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled }
}
