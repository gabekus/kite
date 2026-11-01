import Foundation

/// The buttons Kite puts in the sidebar's address field and the page toolbar (View → Show
/// Toolbar), each of which Settings → Advanced → Toolbar can hide. Kite-only: Arc has no such
/// setting. Every button is shown until the user hides it; a hidden button's command still
/// works from the menu bar and its shortcut.
public enum ChromeButton: String, CaseIterable, Sendable {
    case back, forward, reload
    case passwordManager, darkPage
    case pinnedExtensions, extensions
    case siteControls, splitView

    public var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload"
        case .passwordManager: "Password Manager"
        case .darkPage: "Dark Page"
        case .pinnedExtensions: "Pinned Extensions"
        case .extensions: "Extensions"
        case .siteControls: "Site Control Center"
        case .splitView: "Add Split View"
        }
    }

    /// Where it appears, for the Settings list.
    public var location: String {
        switch self {
        case .back, .forward, .reload, .pinnedExtensions, .splitView: "Toolbar"
        case .passwordManager, .darkPage: "Address field"
        case .extensions, .siteControls: "Address field and toolbar"
        }
    }

    /// The UserDefaults key that's true once the user hides it.
    public var hiddenKey: String { "toolbarButtonHidden.\(rawValue)" }

    public func isShown(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: hiddenKey)
    }

    public func setShown(_ shown: Bool, in defaults: UserDefaults = .standard) {
        if shown { defaults.removeObject(forKey: hiddenKey) } else { defaults.set(true, forKey: hiddenKey) }
    }
}
