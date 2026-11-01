import AppKit
import KiteCore

/// Arc's Boost commands: New Boost and Edit Boost (command-bar actions in Arc's MainMenu.nib,
/// hidden from the menu bar) and Window › View Boosts….
extension BrowserWindowController {
    /// A new, empty Boost for the current site, open in its editor.
    @objc func newBoost(_ sender: Any?) {
        guard !isIncognito, let tab = store.state.selectedTab,
              let boost = BoostsModel.shared.create(for: tab.url) else { return NSSound.beep() }
        BoostEditorWindowController.show(boost.id, refresh: refreshAction(for: tab.id), browser: self)
    }

    /// The current site's newest Boost, open in its editor.
    @objc func editBoost(_ sender: Any?) {
        guard !isIncognito, let tab = store.state.selectedTab,
              let boost = BoostsModel.shared.library.boosts(for: tab.url).first else { return NSSound.beep() }
        BoostEditorWindowController.show(boost.id, refresh: refreshAction(for: tab.id), browser: self)
    }

    @objc func viewBoosts(_ sender: Any?) {
        BoostsWindowController.show()
    }

    func validateBoostItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(newBoost(_:)):
            return !isIncognito && BoostLibrary.domain(of: store.state.selectedTab?.url) != nil
        case #selector(editBoost(_:)):
            return !isIncognito && !BoostsModel.shared.library.boosts(for: store.state.selectedTab?.url).isEmpty
        case #selector(viewBoosts(_:)):
            return true
        default:
            return nil
        }
    }

    /// Reloads the tab the editor was opened from, if it's still open.
    private func refreshAction(for tabID: UUID) -> () -> Void {
        { [weak self] in self?.pool.loadedPage(tabID)?.reload() }
    }
}
