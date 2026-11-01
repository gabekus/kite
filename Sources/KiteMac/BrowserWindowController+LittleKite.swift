import AppKit
import KiteCore

extension BrowserWindowController {
    /// A page from a Little Kite window becomes a tab in `spaceID` (selected, so its space comes
    /// forward), keeping its history and state: the live page moves, nothing reloads.
    /// `profileDirectory` is the profile the page was made in: if the space uses another one, the
    /// page loads again in that space's profile.
    func adopt(_ page: WebPage, url: URL?, title: String?, in spaceID: UUID?, profileDirectory: String? = nil) {
        let id = pool.adopt(page, profileDirectory: profileDirectory)
        store.mutate { _ = $0.openTab(id: id, url: url, in: spaceID) }
        store.pageTitleChanged(id, title)
        if profileDirectory != nil { pool.discardPagesInWrongProfile() }
        // A background test run stays behind the user's windows.
        if !UIDiagnostics.enabledByEnvironment { window?.makeKeyAndOrderFront(nil) }
    }
}
