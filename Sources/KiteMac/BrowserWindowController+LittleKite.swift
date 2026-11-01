import AppKit
import KiteCore

extension BrowserWindowController {
    /// A page from a Little Kite window becomes a tab in `spaceID` (selected, so its space comes
    /// forward), keeping its history and state: the live page moves, nothing reloads.
    func adopt(_ page: WebPage, url: URL?, title: String?, in spaceID: UUID?) {
        let id = pool.adopt(page)
        store.mutate { _ = $0.openTab(id: id, url: url, in: spaceID) }
        store.pageTitleChanged(id, title)
        window?.makeKeyAndOrderFront(nil)
    }
}
