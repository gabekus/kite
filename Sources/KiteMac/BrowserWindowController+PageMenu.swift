import AppKit
import KiteCore

/// The page's right-click menu: Arc's "Open Link in …" items.
extension BrowserWindowController {
    /// Hooks the page menu up to this window (called once the pool exists).
    func installPageMenu() {
        pool.onOpenLink = { [weak self] _, url, target in self?.openLinkFromPageMenu(url, target) }
        pool.contextMenuHost = { [weak self] in
            guard let self else { return PageContextMenu.Host() }
            return PageContextMenu.Host(
                canAddSplitPane: store.state.canAddSplitPane,
                // Little Kite runs on the normal profile, so an incognito page doesn't offer it.
                showsLittleKite: !isIncognito,
                isIncognito: isIncognito
            )
        }
    }

    func openLinkFromPageMenu(_ url: URL, _ target: PageContextMenu.LinkTarget) {
        let app = NSApp.delegate as? AppDelegate
        switch target {
        case .newTab:
            store.mutate { $0.openTab(url: url, select: false) }
        case .newWindow:
            // From an incognito page Chromium opens another incognito window.
            if isIncognito { app?.openIncognitoWindow(url: url) } else { app?.openNewWindow(url: url) }
        case .splitView:
            store.hideCommandBar()
            guard case .added = store.mutate({ $0.openLinkInSplit(url: url) }) else { return NSSound.beep() }
        case .littleKite:
            app?.openLittleKiteWindow(url: url)
        case .incognitoWindow:
            app?.openIncognitoWindow(url: url)
        }
    }
}
