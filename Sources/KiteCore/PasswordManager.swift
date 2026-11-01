import Foundation

/// The password manager built into Kite (Settings): its browser extension does the
/// filling, saving, passkeys and codes, and Kite installs it and gives it Kite's own ways
/// in (the address field's key, ⇧⌘X, Claude's sign_in).
public enum PasswordManager: String, CaseIterable, Sendable {
    case onePassword = "1password"
    case bitwarden
    /// No password manager built in; extensions stay ordinary extensions.
    case none

    /// UserDefaults key for the choice; unset means `automatic`.
    public static let defaultsKey = "passwordManager"

    public var name: String {
        switch self {
        case .onePassword: "1Password"
        case .bitwarden: "Bitwarden"
        case .none: "None"
        }
    }

    /// Its extension in the Chrome Web Store.
    public var extensionID: String? {
        switch self {
        case .onePassword: "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        case .bitwarden: "nngceckbapebfimnlniiiahkandclblb"
        case .none: nil
        }
    }

    /// The popup page, used until the installed extension's manifest says otherwise.
    public var popupPath: String { "popup/index.html" }

    public var storeURL: URL? { extensionID.flatMap(ChromeWebStore.detailURL(for:)) }

    public var popupURL: URL? {
        extensionID.flatMap { URL(string: "chrome-extension://\($0)/\(popupPath)") }
    }

    /// The desktop app the extension unlocks and fills through.
    public var appPaths: [String] {
        switch self {
        case .onePassword: ["/Applications/1Password.app"]
        case .bitwarden: ["/Applications/Bitwarden.app"]
        case .none: []
        }
    }

    /// The manager whose extension `id` is.
    public init?(extensionID id: String) {
        guard let match = Self.allCases.first(where: { $0.extensionID == id }) else { return nil }
        self = match
    }

    /// The saved choice, or with none saved the first whose app or extension is on this
    /// Mac (1Password first), else 1Password.
    public static func current(saved: String?, installed: (PasswordManager) -> Bool) -> PasswordManager {
        if let saved, let choice = PasswordManager(rawValue: saved) { return choice }
        return [.onePassword, .bitwarden].first(where: installed) ?? .onePassword
    }
}
