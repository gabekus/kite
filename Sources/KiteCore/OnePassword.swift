import Foundation

/// 1Password, built into Kite: its browser extension does the filling, saving, passkeys
/// and codes, and Kite installs it and gives it Kite's own ways in.
public enum OnePassword {
    /// 1Password's extension in the Chrome Web Store.
    public static let extensionID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"
    public static let popupPath = "popup/index.html"

    public static var storeURL: URL { ChromeWebStore.detailURL(for: extensionID)! }
    public static var popupURL: URL { URL(string: "chrome-extension://\(extensionID)/\(popupPath)")! }

    /// The desktop app, which the extension unlocks and fills through.
    public static let appPaths = ["/Applications/1Password.app"]
}
