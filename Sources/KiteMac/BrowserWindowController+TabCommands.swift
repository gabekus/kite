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
    /// Rename and Cancel.
    private func showRenameTabDialog(_ id: UUID) {
        guard let window, let tab = store.state.tab(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab…"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: tab.displayTitle)
        field.placeholderString = "Keep it short and sweet!"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.mutate { $0.renameTab(id, to: field.stringValue) }
        }
    }

    /// View → Collapse / Expand Pinned Tabs for the current space.
    @objc func togglePinnedSection(_ sender: Any?) {
        store.mutate { $0.togglePinnedSection($0.selectedSpaceID) }
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
