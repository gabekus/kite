import AppKit
import KiteCore

/// Profile settings › Your Data and Settings (g100, g101).
extension AppDelegate {
    /// Opens one of Kite's settings pages for `profile` in a new tab, as Arc opens Chromium's
    /// settings pages for the profile selected in Settings: in the current space when it uses
    /// that profile, else in the first space that does, so the page acts on that profile.
    func openSettingsPage(_ page: SettingsPage, profile: String = Profile.defaultDirectory) {
        guard let store = browserStore else { return }
        let state = store.state
        let spaceID = state.selectedProfileDirectory == profile
            ? state.selectedSpaceID
            : state.spaces(usingProfile: profile).first?.id
        guard let spaceID else { return NSSound.beep() }
        store.mutate { state in
            let id = state.openTab(url: page.url, in: spaceID)
            state.update(tab: id) { $0.title = page.tabTitle }
        }
        if !UIDiagnostics.enabledByEnvironment { windowController.window?.makeKeyAndOrderFront(nil) }
    }

    /// Passwords and Credit Cards: Kite's Chromium tabs keep neither (Alloy-style tabs have no
    /// Chrome password manager or card autofill); the password manager Kite fills them from does.
    /// Its popup opens in the main window, in the current space's profile.
    var canOpenProfilePasswordManager: Bool { windowController?.canOpenPasswordManager ?? false }

    func openProfilePasswordManager() {
        guard let windowController else { return }
        if !UIDiagnostics.enabledByEnvironment { windowController.window?.makeKeyAndOrderFront(nil) }
        if !windowController.openPasswordManager() { NSSound.beep() }
    }
}
