import AppKit
import KiteCore

/// The sidebar tab menus' items that need the window (SidebarListCells); the rest change the store inline.
extension BrowserWindowController {
    /// The tab menu's Add Split View: the tab is selected, then Add Split View as from the View menu.
    func addSplitView(with id: UUID) {
        if store.state.selectedTab?.id != id { store.mutate { $0.select(tab: id) } }
        addSplitView(nil)
    }

    /// The tab menu's Open in Split View: the tab (its split, if it's in one) joins the page on screen,
    /// after the focused pane, as a drop on the page's right edge does.
    func openInSplitView(_ id: UUID) {
        let state = store.state
        guard let pane = state.selectedTab?.id else { return NSSound.beep() }
        let ids = [state.sidebarDragID(for: id)]
        guard state.canDropSidebarItems(ids, besidePane: pane) else { return NSSound.beep() }
        store.hideCommandBar()
        var outcome: SidebarDropOutcome?
        store.mutate { outcome = $0.dropSidebarItems(ids, besidePane: pane, before: false) }
        if let outcome { sidebarDropped(outcome, haptic: false) }
    }

    /// The tab menu's Move to › space: a pinned tab goes to the end of that space's pinned items, a Today
    /// tab to the top of its Today, like Arc's "Move to Pinned in" / "Move to Today in".
    /// Through Arc's cross-profile warning, as every user move is.
    func moveTab(_ id: UUID, toSpace spaceID: UUID) {
        guard let tab = store.state.location(of: id) else { return }
        moveTab(id, toSpace: spaceID, pinned: tab.section == .pinned)
    }

    /// Archive Other Tabs / Below / Above, with the Today divider's Clear toast.
    func archiveTabs(_ which: ArchiveTabsRelative, relativeTo id: UUID) {
        showArchivedToast(store.mutate { $0.archiveTabs(which, relativeTo: id) })
    }

    /// "Archived 1 tab" / "Archived N tabs" after a menu or the Today divider archives tabs, or a beep for none.
    func showArchivedToast(_ archived: [BrowserTab]) {
        if archived.isEmpty { return NSSound.beep() }
        showToast(archived.count == 1 ? "Archived 1 tab" : "Archived \(archived.count) tabs")
    }
}
