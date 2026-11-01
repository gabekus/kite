#if canImport(CEFBridge)
import AppKit
import KiteCore

/// The engine side of the password manager built into Kite (PasswordManager, chosen in
/// Settings): installing its extension when its app is on the Mac, and opening its
/// popup from Kite's own buttons and commands.
@MainActor
enum PasswordManagerIntegration {
    private static var install: BackgroundExtensionInstall?

    /// The one Settings chose, else whichever is installed.
    static var current: PasswordManager {
        PasswordManager.current(saved: UserDefaults.standard.string(forKey: PasswordManager.defaultsKey)) {
            isAppInstalled($0) || isExtensionInstalled($0)
        }
    }

    static func isAppInstalled(_ manager: PasswordManager) -> Bool {
        manager.appPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    static func isExtensionInstalled(_ manager: PasswordManager) -> Bool {
        manager.extensionID.map { BackgroundExtensionInstall.installedIDs().contains($0) } ?? false
    }

    /// Set once Kite has asked to install a manager's extension, so a "Cancel" sticks.
    /// (1Password's key predates Bitwarden.)
    private static func offeredKey(_ manager: PasswordManager) -> String {
        manager == .onePassword ? "onePasswordInstallOffered" : "\(manager.rawValue)InstallOffered"
    }

    /// With the chosen manager's app installed and its extension not, starts the store's
    /// Add flow in the background. Chrome's own "Add …?" dialog still asks, once.
    static func installIfNeeded(engine: WebEngine) {
        let manager = current
        guard let id = manager.extensionID, let store = manager.storeURL, isAppInstalled(manager),
              !isExtensionInstalled(manager), install == nil,
              !UserDefaults.standard.bool(forKey: offeredKey(manager)) else { return }
        UserDefaults.standard.set(true, forKey: offeredKey(manager))
        install = BackgroundExtensionInstall(extensionID: id, storeURL: store, engine: engine, source: nil) { install = nil }
    }

    /// The chosen manager's popup (search, fill, copy, codes) hanging from `rect` in
    /// `view`. False if none is chosen or its extension isn't installed.
    @discardableResult
    static func showPopup(engine: WebEngine, relativeTo rect: NSRect, of view: NSView, popupURL: URL? = nil) -> Bool {
        let manager = current
        guard isExtensionInstalled(manager), let url = popupURL ?? manager.popupURL else { return false }
        ExtensionPopover.show(url, engine: engine, relativeTo: rect, of: view)
        return true
    }
}
#endif
