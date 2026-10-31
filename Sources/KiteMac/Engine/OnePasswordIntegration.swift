#if canImport(CEFBridge)
import AppKit
import KiteCore

/// The engine side of 1Password in Kite: installing its extension when the 1Password
/// app is on the Mac, and opening its popup from Kite's own buttons and commands.
@MainActor
enum OnePasswordIntegration {
    /// Set once Kite has asked to install the extension, so a "Cancel" sticks.
    static let offeredKey = "onePasswordInstallOffered"
    private static var install: BackgroundExtensionInstall?

    static var isAppInstalled: Bool {
        OnePassword.appPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    static var isExtensionInstalled: Bool {
        BackgroundExtensionInstall.installedIDs().contains(OnePassword.extensionID)
    }

    /// With the 1Password app installed and its extension not, starts the store's Add
    /// flow in the background. Chrome's own "Add 1Password?" dialog still asks, once.
    static func installIfNeeded(engine: WebEngine) {
        guard isAppInstalled, !isExtensionInstalled, install == nil,
              !UserDefaults.standard.bool(forKey: offeredKey) else { return }
        UserDefaults.standard.set(true, forKey: offeredKey)
        install = BackgroundExtensionInstall(extensionID: OnePassword.extensionID, storeURL: OnePassword.storeURL,
                                             engine: engine, source: nil) { install = nil }
    }

    /// 1Password's popup (search, fill, copy, codes) hanging from `rect` in `view`, for
    /// the address field's key button and the command bar. False if it isn't installed.
    @discardableResult
    static func showPopup(engine: WebEngine, relativeTo rect: NSRect, of view: NSView) -> Bool {
        guard isExtensionInstalled else { return false }
        ExtensionPopover.show(OnePassword.popupURL, engine: engine, relativeTo: rect, of: view)
        return true
    }
}
#endif
