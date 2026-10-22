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

    @objc func renameSpace(_ sender: Any?) {
        guard let window else { return }
        let space = store.state.selectedSpace
        let alert = NSAlert()
        alert.messageText = "Rename Space"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: space.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.mutate { $0.renameSpace(space.id, to: field.stringValue) }
        }
    }
}
