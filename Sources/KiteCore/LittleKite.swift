import Foundation

/// Little Kite: Arc's "Little Arc", a small window for links opened from other apps.
/// The decisions that don't need AppKit live here so they can be tested.
public enum LittleKite {
    /// Kite menu → "Open Links from Other Apps in Little Kite". Arc's key is
    /// `openExternalLinksInLittleBrowserEnabled` (in its defaults key list, Arc 1.171).
    public static let opensExternalLinksKey = "openExternalLinksInLittleKite"

    /// On, like Arc: Arc introduces the behaviour with a "Links Open in Little Arc" NUX on the
    /// first external link, and Gabe's Arc defaults have the key at 1. Arc's registered
    /// default itself wasn't found in its binary (see docs/arc-visual-spec.md).
    public static let opensExternalLinksByDefault = true

    public static func opensExternalLinks(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: opensExternalLinksKey) as? Bool ?? opensExternalLinksByDefault
    }

    /// Where a link from another app opens.
    public enum Destination: Equatable, Sendable {
        case littleKite
        case tab
    }

    /// Web links go to Little Kite while the setting is on. Files (an HTML file opened from
    /// Finder) and anything else still open as a tab in the main window.
    public static func destination(for url: URL, opensExternalLinks: Bool) -> Destination {
        guard opensExternalLinks, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .tab
        }
        return .littleKite
    }

    /// The window's title, as the Window menu lists it: Arc's is "Little Arc — <page title>".
    public static func windowTitle(pageTitle: String?) -> String {
        guard let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Little Kite"
        }
        return "Little Kite — " + title
    }

    /// The page's host as the toolbar shows it, without "www.".
    public static func displayHost(of url: URL?) -> String {
        guard let url else { return "" }
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
