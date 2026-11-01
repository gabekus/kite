import AppKit
import KiteCore

/// Arc's Tabs and Spaces menu commands beyond plain selection.
extension BrowserWindowController {
    @objc func selectRecentTab(_ sender: Any?) { store.mutate { $0.selectRecentTab() } }

    @objc func clearToday(_ sender: Any?) {
        let cleared = store.mutate { $0.clearToday() }
        if cleared.isEmpty { return NSSound.beep() }
        showToast(cleared.count == 1 ? "Archived 1 tab" : "Archived \(cleared.count) tabs")
    }

    /// Tabs › Reveal Tab in Sidebar: shows the sidebar, opens the folders the tab is in and
    /// scrolls its row into view.
    @objc func revealTabInSidebar(_ sender: Any?) {
        guard let id = store.state.selectedTab?.id else { return NSSound.beep() }
        if !store.isSidebarVisible { store.toggleSidebar() }
        if let row = store.mutate({ $0.revealTab(id) }) { store.reveal(row: row) }
    }

    /// Arc's `resetTab` binding ("Reset tab to original URL."): the selected pinned tab or
    /// favorite goes back to its pinned page.
    @objc func resetTab(_ sender: Any?) {
        guard let id = store.state.selectedTab?.id, store.state.canReset(tab: id) else { return NSSound.beep() }
        backToPinnedURL(id)
    }

    /// "Back to Pinned URL" on a pinned tab's row.
    func backToPinnedURL(_ id: UUID) {
        guard let url = store.mutate({ $0.resetTab(id) }) else { return }
        load(url, in: id)
    }

    /// "Separate From Pinned Tab": the page moves to a new unpinned tab and the pinned tab goes home.
    func separateFromPinnedTab(_ id: UUID) {
        guard let home = store.state.tab(id)?.pinnedURL,
              store.mutate({ $0.separateFromPinnedTab(id) }) != nil else { return }
        load(home, in: id)
    }

    /// Tabs › Reset all tabs in this Space.
    @objc func resetAllTabsInSpace(_ sender: Any?) {
        let reset = store.mutate { $0.resetPinnedTabs() }
        if reset.isEmpty { return NSSound.beep() }
        for (id, url) in reset { load(url, in: id) }
    }

    /// Loads a URL already set on the tab, if its page is loaded; an unloaded pinned tab
    /// picks it up when it's next opened.
    private func load(_ url: URL, in id: UUID) {
        if InternalPage(url) == nil { pool.loadedPage(id)?.load(url) }
    }

    @objc func duplicateTab(_ sender: Any?) {
        guard let id = store.state.selectedTab?.id else { return NSSound.beep() }
        store.mutate { _ = $0.duplicate(tab: id) }
    }

    /// Renames the space in place in its header, like Arc.
    @objc func renameSpace(_ sender: Any?) { store.beginRenaming(space: store.state.selectedSpaceID) }

    /// The space's icon is one emoji; the field opens the emoji picker.
    func changeIcon(ofSpace id: UUID) {
        guard let window, let space = store.state.spaces.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Change Space Icon"
        alert.informativeText = "Type or pick an emoji."
        alert.addButton(withTitle: "Change")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: space.icon)
        field.frame = NSRect(x: 0, y: 0, width: 60, height: 24)
        field.font = .systemFont(ofSize: 15)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.mutate { $0.setSpaceIcon(space.id, to: field.stringValue) }
        }
        DispatchQueue.main.async {
            field.currentEditor()?.selectAll(nil)
            NSApp.orderFrontCharacterPalette(field)
        }
    }

    func renameFolder(_ id: UUID) {
        guard let window, let found = store.state.folder(matching: id.uuidString) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Folder"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: found.folder.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.mutate { $0.renameFolder(id, to: field.stringValue) }
        }
    }

    /// Arc's folder Delete: asks first (Arc's wording), archives the tabs inside, then
    /// shows Arc's "Folder deleted" toast.
    func deleteFolder(_ id: UUID) {
        guard let window, let found = store.state.folder(matching: id.uuidString) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete your \u{201C}\(found.folder.name)\u{201D} folder?"
        alert.informativeText = "Deleting this folder will archive the tabs inside it."
        alert.addButton(withTitle: "Delete Folder")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            store.mutate { _ = $0.deleteFolder(id) }
            showToast("Folder deleted")
        }
    }

    func deleteSpace(_ id: UUID) {
        guard let window, store.state.spaces.count > 1, let space = store.state.spaces.first(where: { $0.id == id }) else {
            return NSSound.beep()
        }
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(space.name)\u{201D}?"
        alert.informativeText = "Its pinned and unpinned tabs are closed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.mutate { $0.deleteSpace(space.id) }
        }
    }
}
