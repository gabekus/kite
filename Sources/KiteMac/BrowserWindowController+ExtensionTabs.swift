#if canImport(CEFBridge)
import AppKit
import KiteCore

/// The window's tabs as extensions see them (ExtensionTabsBridge): every live tab in
/// every space, in sidebar order, with the selected one active.
extension BrowserWindowController: ExtensionTabsHost {
    var extensionTabs: [ExtensionTab] {
        let state = store.state
        let selected = state.selectedTab?.id
        var seen = Set<UUID>()
        var tabs: [ExtensionTab] = []
        let pinned = Set(state.favorites.map(\.id) + state.spaces.flatMap { $0.pinned.map(\.id) })
        for tab in state.favorites + state.spaces.flatMap(\.allTabs) where seen.insert(tab.id).inserted {
            guard let page = pool.loadedPage(tab.id) as? ChromiumPage else { continue }
            tabs.append(ExtensionTab(id: tab.id, page: page, active: tab.id == selected, pinned: pinned.contains(tab.id)))
        }
        return tabs
    }

    var extensionWindowBounds: CGRect {
        guard let window else { return .zero }
        let screenTop = (window.screen ?? NSScreen.screens.first)?.frame.maxY ?? window.frame.maxY
        return CGRect(x: window.frame.minX, y: screenTop - window.frame.maxY, width: window.frame.width, height: window.frame.height)
    }

    var extensionWindowIsFocused: Bool { NSApp.isActive && window?.isKeyWindow == true }

    var extensionWindowIsFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

    func openTabForExtension(url: URL?, active: Bool) -> ChromiumPage? {
        let id = store.mutate { $0.openTab(url: url, select: active) }
        guard let tab = store.state.tab(id) else { return nil }
        // A background tab loads now, as in Chrome, so the extension gets a working tab.
        return pool.page(for: tab) as? ChromiumPage
    }

    func activateTabForExtension(_ id: UUID) {
        store.mutate { $0.select(tab: id) }
    }
}
#endif

#if canImport(CEFBridge)
extension BrowserWindowController {
    /// ⇧⌘X: 1Password's popup over the top right of the page, for the selected tab.
    @objc func showOnePassword(_ sender: Any?) {
        guard !isIncognito else { return NSSound.beep() }
        let bounds = contentFrame.bounds
        let anchor = NSRect(x: bounds.maxX - 40, y: contentFrame.isFlipped ? bounds.minY : bounds.maxY - 1, width: 1, height: 1)
        if !OnePasswordIntegration.showPopup(engine: pool.engine, relativeTo: anchor, of: contentFrame) { NSSound.beep() }
    }
}
#endif
