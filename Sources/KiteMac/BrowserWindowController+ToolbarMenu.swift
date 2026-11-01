import AppKit
import KiteCore
import SwiftUI

/// View › Show Toolbar's bar, with Arc's right-click menu (`ToolbarMenu` in KiteCore).
final class PageToolbarHost: NSHostingView<PageToolbar> {
    /// Builds the menu for a right-click (or ⌃-click) anywhere on the bar; nil for none.
    var contextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?() ?? super.menu(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenu else { return super.rightMouseDown(with: event) }
        // Nil under the test hook too, which has already logged the menu.
        if let menu = contextMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

extension BrowserWindowController {
    /// Arc's `commandBarToolbarContextMenuActions` for the selected tab. Under KITE_TEST_CONTEXT_MENU the
    /// menu is logged (and an item picked) instead of shown.
    func toolbarContextMenu(from host: NSView) -> NSMenu? {
        let url = store.state.selectedTab?.url
        #if canImport(CEFBridge)
        let extensions = extensionsSelection
        #endif
        let items = ToolbarMenu.items(
            hasURL: url != nil,
            isWebPage: url.map { InternalPage($0) == nil } ?? false,
            extensionsAvailable: {
                #if canImport(CEFBridge)
                extensions != nil
                #else
                false
                #endif
            }(),
            showsFullURL: ToolbarURL.showsFullURL(),
            showsToolbar: store.state.showsToolbar
        )
        guard !items.isEmpty else { return nil }

        let menu = NSMenu(title: "Toolbar")
        menu.autoenablesItems = false
        for entry in items {
            guard let title = entry.title else {
                menu.addItem(.separator())
                continue
            }
            let item = ToolbarMenuAction(title: title) { [weak self, weak host] in
                guard let self else { return }
                switch entry {
                case .copyURL: copyURL(nil)
                case .share: share(nil)
                case .capture: capturePage(nil)
                case .captureFullPage: captureFullPage(nil)
                case .capturePortraitMode: capturePortraitMode(nil)
                case .manageExtensions:
                    #if canImport(CEFBridge)
                    // Under the bar's right end, where its extensions sit.
                    if let host, let model = extensions?.model {
                        let rect = NSRect(x: host.bounds.maxX - 56, y: host.isFlipped ? host.bounds.maxY - 4 : 4, width: 1, height: 1)
                        ExtensionsMenu.present(model: model, from: host, rect: rect)
                    }
                    #endif
                case .fullURL: (NSApp.delegate as? AppDelegate)?.toggleToolbarFullURLs(nil)
                case .toolbar: toggleToolbar(nil)
                case .separator: break
                }
            }
            item.isEnabled = entry.isEnabled
            menu.addItem(item)
        }

        if PageContextMenuItems.testMode != nil {
            let pick = PageContextMenuItems.logForTest(menu.items.map { ($0.isSeparatorItem ? nil : $0.title, $0.isEnabled) })
            if let pick { menu.performActionForItem(at: pick) }
            return nil
        }
        return menu
    }
}

private final class ToolbarMenuAction: NSMenuItem {
    private let body: () -> Void

    init(title: String, _ body: @escaping () -> Void) {
        self.body = body
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run(_ sender: Any?) { body() }
}
