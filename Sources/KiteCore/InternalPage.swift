import Foundation

/// Kite's own pages. A tab on one of these URLs never loads in the engine; the window draws
/// the page natively over the tab's content area.
public enum InternalPage: String, CaseIterable, Sendable {
    /// Arc's ⌘Y "Opens your History in a new Today tab" (chrome://history there).
    case history
    /// The archive as a tab. Archive › View Archive… now opens the Library's Archive page, as in Arc;
    /// kite://archive still works when typed or restored.
    case archive
    /// One site's permissions: what Site Controls' "All Site Settings…" opens. Arc opens
    /// Chromium's site details page there (`arc://settings/content/siteDetails?site=<URL>`);
    /// Kite draws its own, as it does for History. `kite://site-settings?site=<origin>`.
    case siteSettings = "site-settings"
    /// Profile settings › Your Data and Settings: Chromium's settings pages that Arc opens there
    /// (`arc://settings/privacy`, `…/clearBrowserData`, `…/content/notifications`), drawn by
    /// Kite. The path picks the page (`SettingsPage`).
    case settings
    /// Settings › Profiles › "Search Settings…": the default search engine and the Site Search
    /// shortcuts. Arc opens Chromium's page there (`arc://settings/searchEngines`, "Manage search
    /// engines and site search"); Kite draws its own over its Site Search store. `kite://search-engines`.
    case searchEngines = "search-engines"

    public static let scheme = "kite"

    public init?(_ url: URL?) {
        guard let url, url.scheme?.lowercased() == Self.scheme,
              let page = InternalPage(rawValue: (url.host() ?? "").lowercased()) else { return nil }
        self = page
    }

    public var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    public var title: String {
        switch self {
        case .history: "History"
        case .archive: "Archive"
        case .siteSettings: "Site Settings"
        case .settings: "Settings"
        case .searchEngines: "Manage search engines and site search"
        }
    }

    /// The site settings page for the site `url` is on (its origin, as Chromium keys
    /// permissions). Nil for pages that aren't websites.
    public static func siteSettingsURL(for url: URL?) -> URL? {
        guard let url, SiteControls.applies(to: url), let origin = SiteControls.origin(of: url) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = InternalPage.siteSettings.rawValue
        components.queryItems = [URLQueryItem(name: "site", value: origin)]
        return components.url
    }

    /// The site a site settings page is about, or nil if `url` isn't one (or names no website).
    public static func site(inSiteSettings url: URL?) -> URL? {
        guard InternalPage(url) == .siteSettings, let url,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "site" })?.value,
              let site = URL(string: value), SiteControls.applies(to: site) else { return nil }
        return site
    }
}
