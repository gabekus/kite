import AppKit
import KiteCore

extension BrowserWindowController {
    /// The sidebar's hover over a favorite's tile: its preview card (none in incognito windows,
    /// which keep no sign-ins or history to show).
    func previewFavorite(_ tab: BrowserTab?, anchor: NSView?) {
        guard !isIncognito else { return }
        favoritePreviews.hover(tab, anchor: anchor)
    }

    /// A row or button in a favorite's preview: the favorite shows it.
    func openInFavorite(_ id: UUID, _ url: URL) {
        store.mutate {
            $0.select(tab: id)
            $0.update(tab: id) { $0.url = url }
        }
        if InternalPage(url) == nil { pool.loadedPage(id)?.load(url) }
    }
}
