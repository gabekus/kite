#if canImport(CEFBridge)
import AppKit
import KiteCore

/// The engine side of 1Password in Kite: installing its extension when the 1Password
/// app is on the Mac, and opening its popup from Kite's own buttons and commands.
@MainActor
enum OnePasswordIntegration {
    /// Set once Kite has asked to install the extension, so a "Cancel" sticks. Each profile
    /// has its own extensions, so each is asked once: the default profile remembers in
    /// UserDefaults, the others with a file in their folder, which goes when they're deleted.
    static let offeredKey = "onePasswordInstallOffered"
    private static var installs: [String: BackgroundExtensionInstall] = [:]

    private static func wasOffered(_ profile: String) -> Bool {
        profile == Profile.defaultDirectory
            ? UserDefaults.standard.bool(forKey: offeredKey)
            : FileManager.default.fileExists(atPath: offeredMarker(profile).path)
    }

    private static func markOffered(_ profile: String) {
        if profile == Profile.defaultDirectory { return UserDefaults.standard.set(true, forKey: offeredKey) }
        try? FileManager.default.createDirectory(at: ProfileFolders.folder(profile), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: offeredMarker(profile).path, contents: Data())
    }

    private static func offeredMarker(_ profile: String) -> URL {
        ProfileFolders.folder(profile).appendingPathComponent("Kite 1Password Offered")
    }

    static var isAppInstalled: Bool {
        OnePassword.appPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Whether 1Password's extension is in `engine`'s profile.
    static func isExtensionInstalled(in engine: WebEngine) -> Bool {
        guard let profile = engine.profileDirectory else { return false }
        return BackgroundExtensionInstall.installedIDs(profile: profile).contains(OnePassword.extensionID)
    }

    /// With the 1Password app installed and its extension not in `engine`'s profile, starts the
    /// store's Add flow in the background. Chrome's own "Add 1Password?" dialog still asks, once
    /// per profile.
    static func installIfNeeded(engine: WebEngine) {
        guard let profile = engine.profileDirectory, isAppInstalled, !isExtensionInstalled(in: engine),
              installs[profile] == nil, !wasOffered(profile) else { return }
        markOffered(profile)
        installs[profile] = BackgroundExtensionInstall(extensionID: OnePassword.extensionID, storeURL: OnePassword.storeURL,
                                                       engine: engine, source: nil) { installs[profile] = nil }
    }

    /// 1Password's popup (search, fill, copy, codes) hanging from `rect` in `view`, for
    /// the address field's key button and the command bar. False if it isn't installed.
    @discardableResult
    static func showPopup(engine: WebEngine, relativeTo rect: NSRect, of view: NSView) -> Bool {
        guard isExtensionInstalled(in: engine) else { return false }
        ExtensionPopover.show(OnePassword.popupURL, engine: engine, relativeTo: rect, of: view)
        return true
    }
}
#endif
