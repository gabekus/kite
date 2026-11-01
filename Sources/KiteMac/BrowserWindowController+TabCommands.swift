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
