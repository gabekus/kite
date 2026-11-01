#if canImport(CEFBridge)
import AppKit
import KiteCore

/// The engine side of the password manager built into Kite (PasswordManager, chosen in
/// Settings): installing its extension when its app is on the Mac, and opening its popup
/// from Kite's own buttons and commands.
@MainActor
enum PasswordManagerIntegration {
    private static var installs: [String: BackgroundExtensionInstall] = [:]

    /// The one Settings chose, else whichever is installed.
    static var current: PasswordManager {
        PasswordManager.current(saved: UserDefaults.standard.string(forKey: PasswordManager.defaultsKey)) {
            isAppInstalled($0) || installedAnywhere($0)
        }
    }

    static func isAppInstalled(_ manager: PasswordManager) -> Bool {
        manager.appPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Whether the chosen manager's extension is in `engine`'s profile.
    static func isExtensionInstalled(in engine: WebEngine) -> Bool {
        guard let id = current.extensionID, let profile = engine.profileDirectory else { return false }
        return BackgroundExtensionInstall.installedIDs(profile: profile).contains(id)
    }

    private static func installedAnywhere(_ manager: PasswordManager) -> Bool {
        guard let id = manager.extensionID else { return false }
        return BackgroundExtensionInstall.installedIDs(profile: Profile.defaultDirectory).contains(id)
    }

    // MARK: Installing

    /// Set once Kite has asked to install a manager's extension, so a "Cancel" sticks. Each
    /// profile has its own extensions, so each is asked once: the default profile remembers in
    /// UserDefaults, the others with a file in their folder, which goes when they're deleted.
    /// (1Password's names predate Bitwarden.)
    private static func offeredKey(_ manager: PasswordManager) -> String {
        manager == .onePassword ? "onePasswordInstallOffered" : "\(manager.rawValue)InstallOffered"
    }

    private static func offeredMarker(_ manager: PasswordManager, _ profile: String) -> URL {
        ProfileFolders.folder(profile).appendingPathComponent("Kite \(manager.name) Offered")
    }

    private static func wasOffered(_ manager: PasswordManager, _ profile: String) -> Bool {
        profile == Profile.defaultDirectory
            ? UserDefaults.standard.bool(forKey: offeredKey(manager))
            : FileManager.default.fileExists(atPath: offeredMarker(manager, profile).path)
    }

    private static func markOffered(_ manager: PasswordManager, _ profile: String) {
        if profile == Profile.defaultDirectory { return UserDefaults.standard.set(true, forKey: offeredKey(manager)) }
        try? FileManager.default.createDirectory(at: ProfileFolders.folder(profile), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: offeredMarker(manager, profile).path, contents: Data())
    }

    /// With the chosen manager's app installed and its extension not in `engine`'s profile,
    /// starts the store's Add flow in the background. Chrome's own "Add …?" dialog still
    /// asks, once per manager and profile.
    static func installIfNeeded(engine: WebEngine) {
        let manager = current
        guard let id = manager.extensionID, let store = manager.storeURL, let profile = engine.profileDirectory,
              isAppInstalled(manager), !isExtensionInstalled(in: engine),
              installs[profile] == nil, !wasOffered(manager, profile) else { return }
        markOffered(manager, profile)
        installs[profile] = BackgroundExtensionInstall(extensionID: id, storeURL: store, engine: engine, source: nil) {
            installs[profile] = nil
        }
    }

    // MARK: Opening

    /// The chosen manager's popup (search, fill, copy, codes) hanging from `rect` in `view`:
    /// `popupURL` when its manifest names one, else the usual page. False if none is chosen
    /// or its extension isn't in `engine`'s profile.
    @discardableResult
    static func showPopup(engine: WebEngine, relativeTo rect: NSRect, of view: NSView, popupURL: URL? = nil) -> Bool {
        guard isExtensionInstalled(in: engine), let url = popupURL ?? current.popupURL else { return false }
        ExtensionPopover.show(url, engine: engine, relativeTo: rect, of: view)
        return true
    }
}
#endif
