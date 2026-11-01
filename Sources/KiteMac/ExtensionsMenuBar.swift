#if canImport(CEFBridge)
import AppKit
import Combine
import KiteCore
import SwiftUI

/// The menu bar's Extensions menu, as in Arc 1.169: one item per installed extension,
/// then Add Extension… and Manage Extensions…. It's how extensions are reached while
/// the sidebar is shown and the page toolbar (with its pinned icons) is off.
@MainActor
final class ExtensionsMenuBar: NSObject, NSMenuDelegate {
    let item: NSMenuItem
    private var model: ExtensionsModel
    private var managePopover: NSPopover?
    private var listChanges: AnyCancellable?

    init(model: ExtensionsModel) {
        self.model = model
        let menu = TypingSafeMenu(title: "Extensions")
        item = NSMenuItem(title: "Extensions", action: nil, keyEquivalent: "")
        item.submenu = menu
        super.init()
        menu.delegate = self
        rebuild(menu, with: [])
        follow(model)
    }

    /// Shows `model`'s extensions: the front window's profile's.
    func show(_ model: ExtensionsModel) {
        guard model !== self.model else { return }
        self.model = model
        follow(model)
    }

    private func follow(_ model: ExtensionsModel) {
        guard let menu = item.submenu else { return }
        // Kept current, not only on open, so it's right for VoiceOver and `ui menu` too.
        listChanges = model.$extensions.receive(on: DispatchQueue.main).sink { [weak self, weak menu] list in
            guard let self, let menu else { return }
            MainActor.assumeIsolated { self.rebuild(menu, with: list) }
        }
        model.refresh()
    }

    /// Before Window, where Arc has it.
    func install(in mainMenu: NSMenu) {
        let window = mainMenu.items.firstIndex { $0.title == "Window" } ?? mainMenu.items.count
        mainMenu.insertItem(item, at: window)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
    }

    private func rebuild(_ menu: NSMenu, with extensions: [InstalledExtension]) {
        menu.removeAllItems()
        for extensionItem in extensions {
            let entry = NSMenuItem(title: extensionItem.name, action: #selector(openExtension(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = extensionItem.id
            entry.isEnabled = extensionItem.enabled && (extensionItem.popupURL ?? extensionItem.optionsURL) != nil
            if let file = extensionItem.iconFile, let image = NSImage(contentsOf: file) {
                image.size = NSSize(width: 16, height: 16)
                entry.image = image
            }
            menu.addItem(entry)
        }
        if !extensions.isEmpty { menu.addItem(.separator()) }
        let add = NSMenuItem(title: "Add Extension…", action: #selector(addExtension(_:)), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let manage = NSMenuItem(title: "Manage Extensions…", action: #selector(manageExtensions(_:)), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    // MARK: Actions

    @objc private func openExtension(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let item = model.extensions.first(where: { $0.id == id }),
              let url = item.popupURL ?? item.optionsURL, let (view, rect) = Self.anchor() else { return }
        ExtensionPopover.show(url, engine: model.engine, relativeTo: rect, of: view)
    }

    @objc private func addExtension(_ sender: Any?) {
        guard let url = URL(string: "https://chromewebstore.google.com/") else { return }
        NSApp.sendAction(#selector(AppDelegate.openURLFromExtensionsMenu(_:)), to: nil, from: url as NSURL)
    }

    @objc private func manageExtensions(_ sender: Any?) {
        guard let (view, rect) = Self.anchor() else { return }
        managePopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ExtensionsMenu(model: model) { [weak popover] in popover?.close() })
        popover.show(relativeTo: rect, of: view, preferredEdge: ExtensionPopover.belowEdge(of: view))
        managePopover = popover
    }

    /// The top-right corner of the front browser window's page, where the toolbar's
    /// extensions button would be.
    private static func anchor() -> (NSView, NSRect)? {
        let controller = NSApp.keyWindow?.windowController as? BrowserWindowController
            ?? NSApp.mainWindow?.windowController as? BrowserWindowController
        guard let view = controller?.contentFrame else { return nil }
        let bounds = view.bounds
        let y = view.isFlipped ? bounds.minY + 4 : bounds.maxY - 5
        return (view, NSRect(x: bounds.maxX - 56, y: y, width: 1, height: 1))
    }
}
#endif
