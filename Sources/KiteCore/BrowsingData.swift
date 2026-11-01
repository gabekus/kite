import Foundation

/// Profile settings › Your Data and Settings (g100, g101). Arc's five rows open Chromium's own
/// pages for the profile (ADK.ChromiumBrowser builds `settings/privacy`, `password-manager/
/// passwords`, `settings/payments`, `settings/content/notifications` and `settings/
/// clearBrowserData`). Kite's tabs can't show Chromium's settings pages, so Kite draws its own
/// under kite://settings/… and keeps their names, layout and wording from Chromium 156 (Arc 1.171's
/// Chromium), read from Arc's locale.pak and settings resources.
public enum SettingsPage: Equatable, Sendable {
    /// "Privacy and security": Delete browsing data and Site settings.
    case privacy
    /// The privacy page with the Delete browsing data dialog over it, as Chromium's route.
    case clearBrowserData
    /// Site settings: the permissions Kite keeps per site.
    case siteSettings
    /// One permission's default and the sites allowed or blocked.
    case permission(SitePermission)

    /// kite://settings/<path>, the path as Chromium's (`content/notifications`).
    public init?(_ url: URL?) {
        guard InternalPage(url) == .settings, let url else { return nil }
        let path = url.path().split(separator: "/").joined(separator: "/")
        switch path {
        case "privacy": self = .privacy
        case "clearBrowserData": self = .clearBrowserData
        case "content": self = .siteSettings
        default:
            guard path.hasPrefix("content/"),
                  let permission = SitePermission.allCases.first(where: { $0.settingsPath == path.dropFirst(8) })
            else { return nil }
            self = .permission(permission)
        }
    }

    public var url: URL {
        let path = switch self {
        case .privacy: "privacy"
        case .clearBrowserData: "clearBrowserData"
        case .siteSettings: "content"
        case .permission(let permission): "content/" + permission.settingsPath
        }
        return URL(string: "\(InternalPage.scheme)://\(InternalPage.settings.rawValue)/\(path)")!
    }

    /// The page's heading, as Chromium's.
    public var heading: String {
        switch self {
        case .privacy, .clearBrowserData: "Privacy and security"
        case .siteSettings: "Site settings"
        case .permission(let permission): permission.title
        }
    }

    /// Chromium's settings tabs are titled "Settings - <page>".
    public var tabTitle: String { "Settings - " + heading }
}

extension SitePermission {
    /// Chromium's site settings path for the permission (`settings/content/<path>`).
    public var settingsPath: String {
        switch self {
        case .camera: "camera"
        case .microphone: "microphone"
        case .location: "location"
        case .notifications: "notifications"
        }
    }

    /// The Chromium content-settings type name, as in `profile.content_settings.exceptions.<type>`.
    public var contentSettingsType: String {
        switch self {
        case .camera: "media_stream_camera"
        case .microphone: "media_stream_mic"
        case .location: "geolocation"
        case .notifications: "notifications"
        }
    }

    /// The default-behaviour choices, Chromium's wording: sites can ask, or they're blocked.
    public var askDescription: String {
        switch self {
        case .camera: "Sites can ask to use your camera"
        case .microphone: "Sites can ask to use your microphone"
        case .location: "Sites can ask for your location"
        case .notifications: "Sites can ask to send notifications"
        }
    }

    public var blockDescription: String {
        switch self {
        case .camera: "Don't allow sites to use your camera"
        case .microphone: "Don't allow sites to use your microphone"
        case .location: "Don't allow sites to see your location"
        case .notifications: "Don't allow sites to send notifications"
        }
    }

    /// Headings of the "Customized behaviors" lists.
    public var allowedHeading: String {
        switch self {
        case .camera: "Allowed to use your camera"
        case .microphone: "Allowed to use your microphone"
        case .location: "Allowed to see your location"
        case .notifications: "Allowed to send notifications"
        }
    }

    public var blockedHeading: String {
        switch self {
        case .camera: "Not allowed to use your camera"
        case .microphone: "Not allowed to use your microphone"
        case .location: "Not allowed to see your location"
        case .notifications: "Not allowed to send notifications"
        }
    }

    /// The line under "Default behavior".
    public var defaultBehaviorDescription: String {
        switch self {
        case .notifications:
            "Sites automatically follow this setting when you visit them. Sites usually send notifications to let you know about breaking news or chat messages."
        default: "Sites automatically follow this setting when you visit them"
        }
    }
}

/// What Delete browsing data can delete, in Chromium's order and with its labels.
public enum BrowsingDataType: String, CaseIterable, Sendable {
    case history
    case siteData
    case cache
    case downloads
    case formData
    case siteSettings
    case hostedAppData

    public var title: String {
        switch self {
        case .history: "Browsing history"
        case .siteData: "Cookies and other site data"
        case .cache: "Cached images and files"
        case .downloads: "Download history"
        case .formData: "Autofill form data"
        case .siteSettings: "Site settings"
        case .hostedAppData: "Hosted app data"
        }
    }

    /// Chromium's pref for the checkbox (`browser.clear_data.*`), which remembers it per profile.
    public var preference: String {
        switch self {
        case .history: "browser.clear_data.browsing_history"
        case .siteData: "browser.clear_data.cookies"
        case .cache: "browser.clear_data.cache"
        case .downloads: "browser.clear_data.download_history"
        case .formData: "browser.clear_data.form_data"
        case .siteSettings: "browser.clear_data.site_settings"
        case .hostedAppData: "browser.clear_data.hosted_apps_data"
        }
    }

    /// Checked until the user changes it (Chromium's DEFAULT_BROWSING_DATATYPES_LIST).
    public var isCheckedByDefault: Bool { [.history, .siteData, .cache].contains(self) }

    /// The checkboxes shown before Show more: the default three and any other that's checked.
    public static func split(_ available: [BrowsingDataType], checked: Set<BrowsingDataType>)
        -> (shown: [BrowsingDataType], more: [BrowsingDataType]) {
        let shown = available.filter { $0.isCheckedByDefault || checked.contains($0) }
        return (shown, available.filter { !shown.contains($0) })
    }
}

/// Delete browsing data's time range: chips, then More ▾ with the rest.
public enum BrowsingDataPeriod: Int, CaseIterable, Sendable {
    // Chromium's TimePeriod values, which its `browser.clear_data.time_period` pref stores.
    case lastHour = 0
    case lastDay = 1
    case lastWeek = 2
    case fourWeeks = 3
    case allTime = 4
    case lastFifteenMinutes = 6

    /// The chip order.
    public static let ordered: [BrowsingDataPeriod] = [.lastFifteenMinutes, .lastHour, .lastDay, .lastWeek, .fourWeeks, .allTime]
    /// Chromium's default selection.
    public static let `default` = BrowsingDataPeriod.lastHour
    public static let preference = "browser.clear_data.time_period"

    /// The chip's label; `short` is false for the toast.
    public func title(short: Bool = true) -> String {
        switch self {
        case .lastFifteenMinutes: short ? "Last 15 min" : "Last 15 minutes"
        case .lastHour: "Last hour"
        case .lastDay: "Last 24 hours"
        case .lastWeek: "Last 7 days"
        case .fourWeeks: "Last 4 weeks"
        case .allTime: "All time"
        }
    }

    /// The oldest data deleted; nil deletes everything.
    public func since(_ now: Date) -> Date? {
        let minutes: Double? = switch self {
        case .lastFifteenMinutes: 15
        case .lastHour: 60
        case .lastDay: 24 * 60
        case .lastWeek: 7 * 24 * 60
        case .fourWeeks: 28 * 24 * 60
        case .allTime: nil
        }
        return minutes.map { now.addingTimeInterval(-$0 * 60) }
    }

    /// Chromium's chips: the first `maxChips - 1` periods, then the selected one if it's not among
    /// them (else the next); the rest go in the More menu.
    public static func chips(selected: BrowsingDataPeriod, maxChips: Int = 4) -> (shown: [BrowsingDataPeriod], more: [BrowsingDataPeriod]) {
        var shown = Array(ordered.prefix(max(0, maxChips - 1)))
        shown.append(shown.contains(selected) ? ordered[min(maxChips - 1, ordered.count - 1)] : selected)
        return (shown, ordered.filter { !shown.contains($0) })
    }

    /// The toast after deleting: "<period> deleted", or "Deleted" for all time.
    public var deletedMessage: String {
        self == .allTime ? "Deleted" : "\(title(short: false)) deleted"
    }
}

/// One site's entry in a permission's "Customized behaviors" (Chromium's content-settings
/// exceptions pref: `{"https://example.com:443,*": {"setting": 1, "last_modified": "1338…"}}`).
public struct PermissionException: Equatable, Sendable {
    /// The pref's key, kept to write the entry back or remove it.
    public var key: String
    public var site: String
    public var value: SitePermissionValue
    public var lastModified: Date?

    /// The exceptions in `pref`, sorted by site. Values other than allow (1) and block (2) are left out.
    public static func list(_ pref: Any?) -> [PermissionException] {
        guard let pref = pref as? [String: Any] else { return [] }
        return pref.compactMap { key, entry -> PermissionException? in
            guard let entry = entry as? [String: Any] else { return nil }
            let value: SitePermissionValue
            switch (entry["setting"] as? NSNumber)?.intValue {
            case 1: value = .allow
            case 2: value = .block
            default: return nil
            }
            return PermissionException(key: key, site: displaySite(key), value: value, lastModified: modified(entry))
        }
        .sorted { ($0.site, $0.key) < ($1.site, $1.key) }
    }

    /// The pref without the entries changed at or after `since` (nil: all of them), as Delete
    /// browsing data's "Site settings" does.
    public static func removing(from pref: Any?, since: Date?) -> [String: Any] {
        guard let pref = pref as? [String: Any] else { return [:] }
        guard let since else { return [:] }
        return pref.filter { _, entry in
            guard let entry = entry as? [String: Any], let date = modified(entry) else { return true }
            return date < since
        }
    }

    /// "https://example.com:443,*" → "https://example.com" (Chromium lists sites without the
    /// default port and the wildcard secondary pattern).
    static func displaySite(_ key: String) -> String {
        var site = String(key.split(separator: ",", maxSplits: 1).first ?? "")
        for (scheme, port) in [("https://", ":443"), ("http://", ":80")] where site.hasPrefix(scheme) && site.hasSuffix(port) {
            site.removeLast(port.count)
        }
        return site
    }

    /// `last_modified` is a string of microseconds since 1601 (Chromium's base::Time).
    static func modified(_ entry: [String: Any]) -> Date? {
        let raw = entry["last_modified"]
        let micros = (raw as? String).flatMap(Int64.init) ?? (raw as? NSNumber)?.int64Value
        return micros.map(History.chromiumDate)
    }
}

extension History {
    /// Delete browsing data's history: pages last visited at or after `since` (nil: all).
    /// Kite keeps one last visit per page, so a page visited in the range goes entirely.
    public mutating func removeVisits(since: Date?) {
        guard let since else { return removeAll() }
        remove(entries.values.filter { $0.lastVisit >= since }.map(\.url))
    }
}

extension DownloadList {
    /// Delete browsing data's download history: finished downloads started at or after `since`.
    /// Files stay where they are, and downloads still running stay listed.
    public mutating func removeHistory(since: Date?) {
        for item in items where item.state != .inProgress && (since.map { item.startedAt >= $0 } ?? true) {
            remove(item.id)
        }
    }
}
