import AppKit
import KiteCore

/// Arc's Tabs and Spaces menu commands beyond plain selection.
extension BrowserWindowController {
    @objc func selectRecentTab(_ sender: Any?) { store.mutate { $0.selectRecentTab() } }

    @objc func clearToday(_ sender: Any?) {
        clearToday(inSpace: store.state.selectedSpace.id)
    }

    /// Clear Today for one space: ⇧⌘K, and the Clear button on that space's Today divider.
    func clearToday(inSpace spaceID: UUID) {
        let cleared = store.mutate { $0.clearToday(inSpace: spaceID) }
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

    /// "Edit Pinned Page › Edit…": Arc's Edit Pinned URL dialog (WindowData+Dialogs), with its
    /// line "This is what opens first when you click this tab or its favicon.", a field holding
    /// the pinned URL (placeholder "Enter a URL…"), and Save and Cancel.
    func editPinnedURL(_ id: UUID) {
        guard let window, let tab = store.state.tab(id), let pinned = tab.pinnedURL else { return }
        ArcDialog.present(
            on: window,
            title: "Edit Pinned URL",
            message: "This is what opens first when you click this tab or its favicon.",
            field: .init(text: pinned.absoluteString, placeholder: "Enter a URL…"),
            actions: [.init(title: "Cancel", role: .cancel), .init(title: "Save", role: .primary)],
            width: 393
        ) { [weak self] action, text in
            guard action == 1, let self else { return }
            if !self.store.mutate({ $0.editPinnedURL(id, to: text) }) { NSSound.beep() }
        }
    }

    /// "Edit Pinned Page › Replace Pinned URL with Current".
    func replacePinnedURLWithCurrent(_ id: UUID) {
        if !store.mutate({ $0.replacePinnedURLWithCurrent(id) }) { NSSound.beep() }
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

    /// Arc's "Rename Current Tab…": edits the tab's title in place in the sidebar, or, with the
    /// sidebar hidden (or the tab a favorite or split pane), in Arc's "Rename Tab…" dialog.
    @objc func renameCurrentTab(_ sender: Any?) {
        guard let tab = store.state.selectedTab else { return NSSound.beep() }
        renameTab(tab.id)
    }

    func renameTab(_ id: UUID) {
        // Favorites and split panes have no title row to edit in.
        let hasRow = !store.state.favorites.contains { $0.id == id } && store.state.split(containing: id) == nil
        if store.isSidebarVisible && hasRow {
            store.beginRenaming(tab: id)
        } else {
            showRenameTabDialog(id)
        }
    }

    /// Arc's dialog (WindowData+Dialogs): "Rename Tab…", placeholder "Keep it short and sweet!",
    /// Rename and Cancel, in Arc's own dialog sheet.
    private func showRenameTabDialog(_ id: UUID) {
        guard let window, let tab = store.state.tab(id) else { return }
        ArcDialog.present(
            on: window,
            title: "Rename Tab…",
            field: .init(text: tab.displayTitle, placeholder: "Keep it short and sweet!"),
            actions: [.init(title: "Cancel", role: .cancel), .init(title: "Rename", role: .primary)]
        ) { [weak self] action, text in
            guard action == 1 else { return }
            self?.store.mutate { $0.renameTab(id, to: text) }
        }
    }

    /// View → Collapse / Expand Pinned Tabs for the current space.
    @objc func togglePinnedSection(_ sender: Any?) {
        store.mutate { $0.togglePinnedSection($0.selectedSpaceID) }
    }

    /// Renames the space in place in its header, like Arc.
    @objc func renameSpace(_ sender: Any?) { store.beginRenaming(space: store.state.selectedSpaceID) }

    /// Arc's icon picker, hanging under the space's header icon.
    func changeIcon(ofSpace id: UUID) { store.requestIconPicker(space: id) }

    /// A folder's Rename…: edits its name in place in its sidebar row, like a tab's title.
    func renameFolder(_ id: UUID) {
        guard store.state.folder(matching: id.uuidString) != nil else { return }
        store.beginRenaming(folder: id)
    }

    /// Arc's folder Delete: asks first (Arc's wording), archives the tabs inside, then
    /// shows Arc's "Folder deleted" toast.
    func deleteFolder(_ id: UUID) {
        guard let window, let found = store.state.folder(matching: id.uuidString) else { return }
        if let live = found.folder.live { return deleteLiveFolder(id, source: live.source, window: window) }
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

    /// Arc's Delete Live Folder alert. Its tabs go without being archived: the next refresh would bring them back.
    private func deleteLiveFolder(_ id: UUID, source: LiveFolder.Source, window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Delete your \(source.displayName) Live Folder?"
        alert.informativeText = "You can restore this folder at any time by right-clicking the sidebar."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if let controller = LiveFoldersController.shared {
                controller.delete(id)
            } else {
                self?.store.mutate { $0.deleteLiveFolder(id) }
            }
        }
    }

    func deleteSpace(_ id: UUID) {
        guard let window, store.state.spaces.count > 1, let space = store.state.spaces.first(where: { $0.id == id }) else {
            return NSSound.beep()
        }
        // Arc deletes an empty space straight away (observed 1 Nov 2026) and asks first only when tabs
        // would close (its "Delete the space and close all tabs within it" alert, from the binary).
        if store.spaceCreation?.spaceID == space.id { return store.cancelNewSpace() }
        if space.allTabs.isEmpty { return store.mutate { $0.deleteSpace(space.id) } }
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
