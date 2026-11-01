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

    /// Window › View Boosts… ("Opens the Boosts section of your Library", arc-strings ~62221):
    /// the Library's Boosts page.
    @objc func viewBoosts(_ sender: Any?) {
        library.open(.boosts)
    }

    /// A Boost picked on Library › Boosts (Arc's onSelectBoost → showBoostsEditorForURL): its site
    /// in a new tab, which leaves the Library, with the Boost's editor tied to that tab so Refresh
    /// and Zap work on it.
    func openBoostFromLibrary(_ boost: Boost) {
        guard let url = URL(string: "https://\(boost.domain)/") else { return NSSound.beep() }
        if isIncognito {
            // Arc: "Boosts can't be installed or used in Incognito Mode"; edit without a page.
            BoostEditorWindowController.show(boost.id, refresh: nil)
            return
        }
        let tabID = store.mutate { $0.openTab(url: url) }
        BoostEditorWindowController.show(boost.id, refresh: refreshAction(for: tabID), browser: self)
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
