import AppKit
import KiteCore

/// Arc's split view commands (View menu).
extension BrowserWindowController {
    /// Adds an empty pane after the focused one and opens the command bar to fill it.
    /// Esc closes the bar and cancels the split (`BrowserStore.hideCommandBar`).
    @objc func addSplitView(_ sender: Any?) {
        guard store.state.selectedTab != nil else { return NSSound.beep() }
        // Arc shows "Cannot Add New Pane" for a fifth; Gabe wants nothing to happen.
        guard (store.state.selectedSplit?.tabIDs.count ?? 0) < SplitView.maxPanes else { return }
        store.hideCommandBar()
        // Marked pending first, so showing the new pane doesn't hand focus to its page.
        let pane = UUID()
        store.pendingSplitPane = pane
        guard store.mutate({ $0.addSplitPane(id: pane) }) == .added(pane) else {
            store.pendingSplitPane = nil
            return
        }
        store.showCommandBar(.editCurrent)
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
