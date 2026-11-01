import AppKit
import KiteCore

/// The page's right-click menu: Arc's "Open Link in …" items, and Save As…, Print… and View
/// Page Source.
extension BrowserWindowController {
    /// Hooks the page menu up to this window (called once the pool exists).
    func installPageMenu() {
        pool.onOpenLink = { [weak self] _, url, target in self?.openLinkFromPageMenu(url, target) }
        if !isIncognito {
            pool.onOpenLittleKite = { _, url in (NSApp.delegate as? AppDelegate)?.openLittleKiteWindow(url: url) }
        }
        pool.onPageCommand = { [weak self] id, command in self?.runPageCommand(command, tab: id) }
        pool.contextMenuHost = { [weak self] in
            guard let self else { return PageContextMenu.Host() }
            return PageContextMenu.Host(
                canAddSplitPane: store.state.canAddSplitPane,
                // Little Kite runs on the normal profile, so an incognito page doesn't offer it.
                showsLittleKite: !isIncognito,
                isIncognito: isIncognito,
                searchEngine: store.state.searchEngine
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

    /// Runs on the right-clicked tab: a split pane that wasn't focused becomes the focused one first.
    func runPageCommand(_ command: PageContextMenu.PageCommand, tab id: UUID) {
        if store.state.selectedTab?.id != id { store.mutate { $0.select(tab: id) } }
        switch command {
        case .savePageAs: savePageAs(nil)
        case .print: printPage(nil)
        case .viewPageSource: viewSource(nil)
        }
    }
}
