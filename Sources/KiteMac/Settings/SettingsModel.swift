import AppKit
import Combine
import KiteCore

/// What the Settings panes read and change. Most settings are already menu commands, so a
/// control runs the command and reads its checkmark the way the menu does (`validateMenuItem`):
/// the window and the menu bar can't disagree, and no setting's logic lives here twice.
@MainActor
final class SettingsModel: ObservableObject {
    /// Bumped to redraw after anything changes, here or in the menu bar.
    @Published private(set) var revision = 0

    func refresh() { revision += 1 }

    // MARK: Menu commands

    /// A menu command, by action and tag (Archive tabs after and Dark Pages use tags).
    struct Command: Hashable {
        var action: Selector
        var tag = 0
    }

    /// Whether the command's menu item is checked, and whether it's enabled.
    func state(_ command: Command) -> (on: Bool, enabled: Bool) {
        guard let item = menuItem(command)?.copy() as? NSMenuItem,
              let target = NSApp.target(forAction: command.action, to: item.target, from: item) as AnyObject?
        else { return (false, false) }
        let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
        return (item.state == .on, enabled)
    }

    func perform(_ command: Command) {
        guard let item = menuItem(command) else { return }
        NSApp.sendAction(command.action, to: item.target, from: item)
        refresh()
    }

    private func menuItem(_ command: Command) -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == command.action && item.tag == command.tag { return item }
                if let found = item.submenu.flatMap(find) { return found }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    // MARK: Browser state

    private var store: BrowserStore? { (NSApp.delegate as? AppDelegate)?.browserStore }

    var searchEngine: SearchEngine {
        get { store?.state.searchEngine ?? .google }
        set { store?.mutate { $0.searchEngine = newValue }; refresh() }
    }

    var archiveAfter: ArchiveInterval { store?.state.archiveAfter ?? .twelveHours }

    /// The profile whose settings Profiles shows beside its list, which has only Default so far.
    var settingsProfile: String { Profile.defaultDirectory }

    var profileSettings: ProfileSettings { store?.state.settings(ofProfile: settingsProfile) ?? ProfileSettings() }

    func updateProfileSettings(_ change: @escaping (inout ProfileSettings) -> Void) {
        let profile = settingsProfile
        store?.mutate { $0.updateSettings(ofProfile: profile, change) }
        refresh()
    }

    /// The Spaces using Kite's one profile, for Profiles' list.
    var spaceCount: Int { store?.state.spaces.count ?? 1 }

    // MARK: Shortcuts

    private var keyBindings: KeyBindingsStore? { (NSApp.delegate as? AppDelegate)?.keyBindings }

    /// Every menu command with an ID, in menu order: the Shortcuts pane's rows.
    var shortcutEntries: [ShortcutEntry] {
        _ = revision
        guard let menu = NSApp.mainMenu, let keyBindings else { return [] }
        return keyBindings.entries(in: menu)
    }

    func setShortcut(_ shortcut: KeyShortcut?, for id: String) {
        keyBindings?.set(KeyBindingOverride(action: id, shortcut: shortcut), menu: NSApp.mainMenu)
        refresh()
    }

    func resetShortcut(_ id: String) {
        keyBindings?.reset(id, menu: NSApp.mainMenu)
        refresh()
    }

    func resetAllShortcuts() {
        keyBindings?.resetAll(menu: NSApp.mainMenu)
        refresh()
    }

    /// Takes `shortcut` away from every other command that has it.
    func removeConflicts(with shortcut: KeyShortcut, keeping id: String) {
        for other in ShortcutsList.conflicts(for: shortcut, excluding: id, in: shortcutEntries) {
            keyBindings?.set(KeyBindingOverride(action: other.id, shortcut: nil), menu: NSApp.mainMenu)
        }
        refresh()
    }
}
