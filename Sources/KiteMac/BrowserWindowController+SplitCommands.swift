import AppKit
import KiteCore

/// Arc's split view commands (View menu).
extension BrowserWindowController {
    /// Adds an empty pane after the focused one and opens the command bar to fill it.
    @objc func addSplitView(_ sender: Any?) {
        switch store.mutate({ $0.addSplitPane() }) {
        case .added:
            store.showCommandBar(.editCurrent)
        case .full:
            // Arc's toast for a fifth pane.
            showToast("Cannot Add New Pane")
        case .noTab:
            NSSound.beep()
        }
    }

    /// Arc's Close this Split Pane: closes the focused pane's tab.
    @objc func closeSplitPane(_ sender: Any?) {
        guard let id = store.state.selectedTab?.id, store.state.selectedSplit != nil else { return NSSound.beep() }
        close(tab: id)
    }

    @objc func separateFromSplitView(_ sender: Any?) {
        guard let id = store.state.selectedTab?.id, store.state.selectedSplit != nil else { return NSSound.beep() }
        store.mutate { $0.separateFromSplit(tab: id) }
    }

    /// Switch to Split View 1…4: tags are the pane number.
    @objc func focusSplitPane(_ sender: NSMenuItem) {
        store.mutate { $0.focusPane(number: sender.tag) }
    }

    @objc func focusNextSplitPane(_ sender: Any?) { store.mutate { $0.focusAdjacentPane(offset: 1) } }
    @objc func focusPreviousSplitPane(_ sender: Any?) { store.mutate { $0.focusAdjacentPane(offset: -1) } }

    /// Menu validation for the split commands; nil for other items.
    func validateSplitItem(_ item: NSMenuItem) -> Bool? {
        let split = store.state.selectedSplit
        switch item.action {
        case #selector(addSplitView(_:)):
            return store.state.selectedTab != nil
        case #selector(closeSplitPane(_:)), #selector(separateFromSplitView(_:)),
             #selector(focusNextSplitPane(_:)), #selector(focusPreviousSplitPane(_:)):
            return split != nil
        case #selector(focusSplitPane(_:)):
            return split.map { $0.tabIDs.count >= item.tag } ?? false
        default:
            return nil
        }
    }
}
