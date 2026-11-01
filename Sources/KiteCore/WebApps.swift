import Foundation

// Installed web apps (PWAs). Arc 1.171 has none (no menu item; "web app installation" in its binary is
// only Chromium's permission-request name), so this is a Kite addition modelled on Chrome and the W3C
// Web App Manifest spec (https://www.w3.org/TR/appmanifest/): File › Install Page as App… reads the
// page's manifest, the app opens in its own window that stays within the manifest's scope, and a small
// launcher bundle in ~/Applications/Kite Apps puts it in Launchpad, Spotlight and the Dock.

/// How the manifest asks to be shown (`display`). Kite opens `browser` apps as a tab and every
/// other mode in an app window, as Chrome does on the Mac.
public enum WebAppDisplay: String, Codable, Sendable, CaseIterable {
    case fullscreen
    case standalone
    case minimalUI = "minimal-ui"
    case browser

    public var opensInWindow: Bool { self != .browser }
}

/// One `icons` entry from a manifest, or an icon `<link>` from the page.
public struct WebAppIcon: Codable, Equatable, Hashable, Sendable {
    public var url: URL
    /// The largest square edge in `sizes`, in pixels; nil for "any" (scalable) or no sizes.
    public var size: Int?
    public var type: String?
    /// The spec's purposes: "any", "maskable", "monochrome". Empty means "any".
    public var purposes: Set<String>

    public init(url: URL, size: Int? = nil, type: String? = nil, purposes: Set<String> = []) {
        self.url = url
        self.size = size
        self.type = type
        self.purposes = purposes
    }

    /// Usable as a full-colour app icon: purpose "any" (the default).
    public var isAnyPurpose: Bool { purposes.isEmpty || purposes.contains("any") }

    /// The largest edge in a `sizes` attribute ("16x16 32x32", "any"), nil when it lists none.
    public static func largestSize(in sizes: String?) -> Int? {
        guard let sizes else { return nil }
        let edges = sizes.lowercased().split(whereSeparator: \.isWhitespace).compactMap { token -> Int? in
            let parts = token.split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
            return min(w, h)
        }
        return edges.max()
    }
}

/// A parsed web app manifest, with the spec's processing applied (URLs resolved, defaults and
/// fallbacks for start_url, id and scope).
public struct WebAppManifest: Equatable, Sendable {
    public var name: String?
    public var shortName: String?
    public var startURL: URL
    /// The app's identity (spec `id`): start_url unless the manifest names one on the same origin.
    public var id: URL
    public var scope: URL
    public var display: WebAppDisplay
    /// `#rrggbb`, nil when absent or not a colour Kite understands.
    public var themeColor: String?
    public var backgroundColor: String?
    public var icons: [WebAppIcon]
    /// `description`, trimmed (WebApps.dialogDescription shortens it for the install dialog).
    public var description: String? = nil
    public var screenshots: [WebAppScreenshot] = []

    /// Parses manifest JSON fetched from `manifestURL` for the page at `documentURL`. Nil when it isn't a
    /// JSON object (the spec then treats the page as having no manifest).
    public static func parse(_ data: Data, manifestURL: URL, documentURL: URL) -> WebAppManifest? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            guard let value = json[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        // start_url: resolved against the manifest; must share the document's origin, else the document.
        var startURL = WebApps.stripFragment(documentURL)
        if let raw = json["start_url"] as? String, let url = URL(string: raw, relativeTo: manifestURL)?.absoluteURL,
           WebApps.isWeb(url), WebApps.sameOrigin(url, documentURL) {
            startURL = WebApps.stripFragment(url)
        }

        // id: resolved against start_url's origin; must share it, else start_url. Fragment dropped.
        var id = startURL
        if let raw = json["id"] as? String, let origin = WebApps.origin(of: startURL).flatMap({ URL(string: $0 + "/") }),
           let url = URL(string: raw, relativeTo: origin)?.absoluteURL, WebApps.sameOrigin(url, startURL) {
            id = WebApps.stripFragment(url)
        }

        // scope: resolved against the manifest, query and fragment dropped; must share start_url's origin
        // and contain it, else start_url's directory.
        var scope = WebApps.defaultScope(for: startURL)
        if let raw = json["scope"] as? String, let url = URL(string: raw, relativeTo: manifestURL)?.absoluteURL,
           WebApps.sameOrigin(url, startURL) {
            let candidate = WebApps.stripQueryAndFragment(url)
            if WebApps.isURL(startURL, withinScope: candidate) { scope = candidate }
        }

        let display = (json["display"] as? String).flatMap { WebAppDisplay(rawValue: $0.lowercased()) } ?? .browser

        var icons: [WebAppIcon] = []
        for entry in json["icons"] as? [[String: Any]] ?? [] {
            guard let src = entry["src"] as? String, let url = URL(string: src, relativeTo: manifestURL)?.absoluteURL,
                  WebApps.isWeb(url) || url.scheme == "data" else { continue }
            let purposes = Set(((entry["purpose"] as? String) ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            icons.append(WebAppIcon(url: url, size: WebAppIcon.largestSize(in: entry["sizes"] as? String),
                                    type: entry["type"] as? String, purposes: purposes))
        }

        var screenshots: [WebAppScreenshot] = []
        for entry in json["screenshots"] as? [[String: Any]] ?? [] {
            guard let src = entry["src"] as? String, let url = URL(string: src, relativeTo: manifestURL)?.absoluteURL,
                  WebApps.isWeb(url) || url.scheme == "data" else { continue }
            screenshots.append(WebAppScreenshot(
                url: url, formFactor: (entry["form_factor"] as? String)?.lowercased(),
                label: (entry["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        return WebAppManifest(
            name: string("name"), shortName: string("short_name"), startURL: startURL, id: id, scope: scope,
            display: display, themeColor: string("theme_color").flatMap(WebApps.normalizedColor),
            backgroundColor: string("background_color").flatMap(WebApps.normalizedColor), icons: icons,
            description: string("description"), screenshots: screenshots
        )
    }
}

/// One `screenshots` entry from a manifest.
public struct WebAppScreenshot: Equatable, Hashable, Sendable {
    public var url: URL
    /// "wide" or "narrow"; nil when the manifest gives none.
    public var formFactor: String?
    public var label: String?

    public init(url: URL, formFactor: String? = nil, label: String? = nil) {
        self.url = url
        self.formFactor = formFactor
        self.label = label
    }
}

/// Chrome's rules for offering and presenting an install (Chromium, components/webapps/browser/installable:
/// installable_evaluator.cc and installable_data_fetcher.cc; components/webapps/common/constants.cc).
public enum WebAppInstallability {
    /// The smallest "any" icon Chrome accepts (kMinimumPrimaryIconSizeInPx).
    public static let minimumIconSize = 144
    /// kMaximumDescriptionLength: the dialog cuts the description here.
    public static let maximumDescriptionLength = 300
    /// kMaximumNumOfScreenshots, kMinimumScreenshotSizeInPx, kMaximumScreenshotSizeInPx, kMaximumScreenshotRatio.
    public static let maximumScreenshots = 8
    public static let minimumScreenshotSize = 320
    public static let maximumScreenshotSize = 3840
    public static let maximumScreenshotRatio = 2.3

    /// Whether Chrome would show its install icon for the manifest: a name or short_name, a display
    /// mode that opens a window, and a purpose-"any" icon at least 144px (or scalable). start_url is
    /// always valid once parsed.
    public static func isPromotable(_ manifest: WebAppManifest) -> Bool {
        guard manifest.name != nil || manifest.shortName != nil, manifest.display.opensInWindow else { return false }
        return manifest.icons.contains { icon in
            guard icon.isAnyPurpose else { return false }
            guard let size = icon.size else {
                // Chrome takes an icon with sizes "any" (an SVG); one with no sizes it sizes by downloading.
                return icon.type?.lowercased().contains("svg") == true || icon.url.pathExtension.lowercased() == "svg"
            }
            return size >= minimumIconSize
        }
    }

    /// The screenshots a desktop dialog fetches: form_factor "wide" only, at most 8, in manifest order.
    public static func desktopScreenshots(_ manifest: WebAppManifest) -> [WebAppScreenshot] {
        Array(manifest.screenshots.filter { $0.formFactor == "wide" }.prefix(maximumScreenshots))
    }

    /// Which downloaded screenshots (pixel sizes, nil where the download failed) the dialog shows, by
    /// index: at least 320px and at most 3840px each way, the same aspect ratio as the first one kept,
    /// and no more than 2.3 times as long as wide.
    public static func acceptedScreenshots(_ sizes: [(width: Int, height: Int)?]) -> [Int] {
        var accepted: [Int] = []
        var first: (width: Int, height: Int)?
        for (index, size) in sizes.enumerated() {
            guard let size, size.width > 0, size.height > 0 else { continue }
            guard min(size.width, size.height) >= minimumScreenshotSize,
                  max(size.width, size.height) <= maximumScreenshotSize else { continue }
            if let first, size.width * first.height != size.height * first.width { continue }
            if Double(max(size.width, size.height)) > Double(min(size.width, size.height)) * maximumScreenshotRatio { continue }
            if first == nil { first = size }
            accepted.append(index)
        }
        return accepted
    }

    /// The description as the dialog shows it: cut to 300 characters.
    public static func dialogDescription(_ description: String?) -> String? {
        guard let description, !description.isEmpty else { return nil }
        return String(description.prefix(maximumDescriptionLength))
    }

    /// The host the dialog shows under the app's name (Chrome shows the start URL's origin without
    /// the scheme).
    public static func displayOrigin(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        if let port = url.port, port != (url.scheme == "https" ? 443 : 80) { return "\(host):\(port)" }
        return host
    }
}

/// What Kite reads from the page itself (WebApps.pageInfoScript): its manifest link, title, icon links
/// and theme-color, for apps without a manifest and for icons the manifest lacks.
public struct WebAppPageInfo: Codable, Equatable, Sendable {
    public struct IconLink: Codable, Equatable, Sendable {
        public var href: String
        public var sizes: String?
        public var rel: String?

        public init(href: String, sizes: String? = nil, rel: String? = nil) {
            self.href = href
            self.sizes = sizes
            self.rel = rel
        }
    }

    public var url: String
    public var title: String?
    public var manifest: String?
    /// The manifest link asks for credentials (`crossorigin="use-credentials"`).
    public var manifestCredentials: Bool?
    public var icons: [IconLink]
    public var themeColor: String?
    public var applicationName: String?

    public init(url: String, title: String? = nil, manifest: String? = nil, manifestCredentials: Bool? = nil,
                icons: [IconLink] = [], themeColor: String? = nil, applicationName: String? = nil) {
        self.url = url
        self.title = title
        self.manifest = manifest
        self.manifestCredentials = manifestCredentials
        self.icons = icons
        self.themeColor = themeColor
        self.applicationName = applicationName
    }

    public static func decode(_ result: Any?) -> WebAppPageInfo? {
        guard let json = result as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WebAppPageInfo.self, from: data)
    }

    public var documentURL: URL? { URL(string: url) }
    public var manifestURL: URL? { manifest.flatMap { URL(string: $0) }.flatMap { WebApps.isWeb($0) ? $0 : nil } }

    /// The page's icon links, apple-touch-icon (usually 180px) counted as its size when it gives none.
    public var iconCandidates: [WebAppIcon] {
        icons.compactMap { link in
            guard let url = URL(string: link.href), WebApps.isWeb(url) || url.scheme == "data" else { return nil }
            let touch = link.rel?.lowercased().contains("apple-touch-icon") == true
            return WebAppIcon(url: url, size: WebAppIcon.largestSize(in: link.sizes) ?? (touch ? 180 : nil))
        }
    }
}

/// An installed app, as webapps.json stores it.
public struct WebApp: Codable, Equatable, Identifiable, Sendable {
    /// 16 hex digits from the manifest id (WebApps.appID): the kite-app:// host and launcher's bundle id.
    public var id: String
    public var manifestID: URL
    public var name: String
    public var startURL: URL
    public var scope: URL
    public var display: WebAppDisplay
    public var themeColor: String?
    public var backgroundColor: String?
    /// Where the icon came from (manifest, page link or favicon), for reinstalling.
    public var iconURL: URL?
    public var manifestURL: URL?
    /// The launcher bundle's file name in the apps folder ("Name.app"), nil when none was written.
    public var shimName: String?
    public var installedAt: Date

    public init(id: String, manifestID: URL, name: String, startURL: URL, scope: URL, display: WebAppDisplay,
                themeColor: String? = nil, backgroundColor: String? = nil, iconURL: URL? = nil,
                manifestURL: URL? = nil, shimName: String? = nil, installedAt: Date = Date()) {
        self.id = id
        self.manifestID = manifestID
        self.name = name
        self.startURL = startURL
        self.scope = scope
        self.display = display
        self.themeColor = themeColor
        self.backgroundColor = backgroundColor
        self.iconURL = iconURL
        self.manifestURL = manifestURL
        self.shimName = shimName
        self.installedAt = installedAt
    }

    /// Whether a navigation to `url` stays in the app window.
    public func contains(_ url: URL) -> Bool { WebApps.isURL(url, withinScope: scope) }

    /// What Kite installs for the page: from its manifest when it has one, else the page itself
    /// (Chrome's "Create Shortcut": the page's URL, title and icon).
    public static func candidate(page: WebAppPageInfo, manifest: WebAppManifest?) -> WebApp? {
        guard let documentURL = page.documentURL, WebApps.isWeb(documentURL) else { return nil }
        let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = page.applicationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let manifest {
            let name = manifest.name ?? manifest.shortName ?? [appName, title].compactMap { $0 }.first { !$0.isEmpty }
                ?? documentURL.host ?? "Web App"
            return WebApp(
                id: WebApps.appID(for: manifest.id), manifestID: manifest.id, name: name, startURL: manifest.startURL,
                scope: manifest.scope, display: manifest.display,
                themeColor: manifest.themeColor ?? page.themeColor.flatMap(WebApps.normalizedColor),
                backgroundColor: manifest.backgroundColor,
                iconURL: WebApps.bestIcon(manifest.icons)?.url ?? WebApps.bestIcon(page.iconCandidates)?.url
                    ?? WebApps.faviconURL(for: documentURL),
                manifestURL: page.manifestURL
            )
        }
        let start = WebApps.stripFragment(documentURL)
        let name = [appName, title].compactMap { $0 }.first { !$0.isEmpty } ?? documentURL.host ?? "Web App"
        return WebApp(
            id: WebApps.appID(for: start), manifestID: start, name: name, startURL: start,
            scope: WebApps.defaultScope(for: start), display: .standalone,
            themeColor: page.themeColor.flatMap(WebApps.normalizedColor),
            iconURL: WebApps.bestIcon(page.iconCandidates)?.url ?? WebApps.faviconURL(for: documentURL)
        )
    }
}

/// The profile's installed apps (webapps.json).
public struct WebAppsState: Codable, Equatable, Sendable {
    public var apps: [WebApp]

    public init(apps: [WebApp] = []) {
        self.apps = apps
    }

    public func app(id: String) -> WebApp? { apps.first { $0.id == id } }

    /// Installing an app that's already there (same manifest id) replaces it in place.
    public mutating func install(_ app: WebApp) {
        if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index] = app } else { apps.append(app) }
    }

    @discardableResult
    public mutating func remove(id: String) -> WebApp? {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return nil }
        return apps.remove(at: index)
    }

    /// For menus: by name, case-insensitively.
    public var sorted: [WebApp] {
        apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

public enum WebApps {
    /// Kite's URL scheme for launching an installed app: `kite-app://<id>` (the launcher opens it).
    public static let scheme = "kite-app"

    public static func launchURL(for id: String) -> URL { URL(string: "\(scheme)://\(id)")! }

    /// The app id in a kite-app:// URL, nil for anything else.
    public static func appID(fromLaunchURL url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, let host = url.host?.lowercased(), isAppID(host) else { return nil }
        return host
    }

    public static func isAppID(_ id: String) -> Bool {
        id.count == 16 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// A stable id from the manifest id (FNV-1a, 64 bits, as hex): reinstalling the same app keeps it.
    public static func appID(for manifestID: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in stripFragment(manifestID).absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// The app window's title: the page's, else the app's name (Chrome's app windows do the same).
    public static func windowTitle(appName: String, pageTitle: String?) -> String {
        guard let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return appName }
        return title
    }

    // MARK: URLs

    public static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    /// scheme://host[:port], lowercased, nil for non-web URLs.
    public static func origin(of url: URL) -> String? {
        guard isWeb(url), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = url.port, port != defaultPort { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let left = origin(of: a) else { return false }
        return left == origin(of: b)
    }

    /// The spec's "within scope": same origin, and the URL's path starts with the scope's path.
    public static func isURL(_ url: URL, withinScope scope: URL) -> Bool {
        guard sameOrigin(url, scope) else { return false }
        return path(of: url).hasPrefix(path(of: scope))
    }

    /// The spec's default scope: start_url up to and including its path's last "/".
    public static func defaultScope(for startURL: URL) -> URL {
        let path = path(of: startURL)
        let directory = path.range(of: "/", options: .backwards).map { String(path[..<$0.upperBound]) } ?? "/"
        guard let origin = origin(of: startURL), let url = URL(string: origin + directory) else { return startURL }
        return url
    }

    /// The URL's path as written (percent escapes kept), "/" when empty.
    static func path(of url: URL) -> String {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? url.path
        return path.isEmpty ? "/" : path
    }

    public static func stripFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    static func stripQueryAndFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.fragment = nil
        components.query = nil
        return components.url ?? url
    }

    public static func faviconURL(for url: URL) -> URL? {
        origin(of: url).flatMap { URL(string: $0 + "/favicon.ico") }
    }

    // MARK: Icons

    /// The icon to use for the app: purpose "any", raster before scalable (NSImage's SVG support is
    /// patchy), then the largest. Nil when there's none.
    public static func bestIcon(_ icons: [WebAppIcon]) -> WebAppIcon? {
        let usable = icons.filter(\.isAnyPurpose)
        func isSVG(_ icon: WebAppIcon) -> Bool {
            icon.type?.lowercased().contains("svg") == true || icon.url.pathExtension.lowercased() == "svg"
        }
        return usable.max { a, b in
            let aRaster = !isSVG(a), bRaster = !isSVG(b)
            if aRaster != bRaster { return !aRaster }
            return (a.size ?? 0) < (b.size ?? 0)
        }
    }

    // MARK: Colours

    /// A CSS colour as `#rrggbb` (alpha dropped): hex forms, rgb()/rgba() with numbers or percentages,
    /// and the common named colours. Nil for anything else.
    public static func normalizedColor(_ css: String) -> String? {
        let value = css.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            let hex = Array(value.dropFirst())
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            switch hex.count {
            case 3, 4: return "#" + hex.prefix(3).map { "\($0)\($0)" }.joined()
            case 6, 8: return "#" + String(hex.prefix(6))
            default: return nil
            }
        }
        if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
            let parts = value[value.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard parts.count >= 3 else { return nil }
            var channels: [Int] = []
            for part in parts.prefix(3) {
                if part.hasSuffix("%"), let percent = Double(part.dropLast()) {
                    channels.append(Int((min(max(percent, 0), 100) / 100 * 255).rounded()))
                } else if let number = Double(part) {
                    channels.append(Int(min(max(number, 0), 255).rounded()))
                } else {
                    return nil
                }
            }
            return "#" + channels.map { hex2($0) }.joined()
        }
        return namedColors[value]
    }

    /// sRGB components 0…1 of a `#rrggbb` colour.
    public static func components(of hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard let normalized = normalizedColor(hex), let value = UInt32(normalized.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    /// Whether dark text and icons read better on the colour (WCAG relative luminance above the
    /// point where black and white have equal contrast).
    public static func prefersDarkForeground(on hex: String) -> Bool {
        guard let (r, g, b) = components(of: hex) else { return true }
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.179
    }

    private static func hex2(_ value: Int) -> String {
        let hex = String(value, radix: 16)
        return hex.count == 1 ? "0" + hex : hex
    }

    private static let namedColors: [String: String] = [
        "black": "#000000", "white": "#ffffff", "red": "#ff0000", "green": "#008000", "blue": "#0000ff",
        "yellow": "#ffff00", "orange": "#ffa500", "purple": "#800080", "gray": "#808080", "grey": "#808080",
        "silver": "#c0c0c0", "navy": "#000080", "teal": "#008080", "maroon": "#800000", "olive": "#808000",
        "lime": "#00ff00", "aqua": "#00ffff", "cyan": "#00ffff", "fuchsia": "#ff00ff", "magenta": "#ff00ff",
        "pink": "#ffc0cb", "brown": "#a52a2a", "indigo": "#4b0082", "gold": "#ffd700",
    ]

    // MARK: Page script

    /// Reads the page's manifest link, title, icon links and theme-color as a JSON string (WebAppPageInfo).
    public static let pageInfoScript = """
        (() => {
          const abs = (h) => { try { return h ? new URL(h, document.baseURI).href : null; } catch (e) { return null; } };
          const manifest = document.querySelector('link[rel~="manifest" i]');
          const icons = Array.from(document.querySelectorAll('link[rel~="icon" i], link[rel~="apple-touch-icon" i]'))
            .map((l) => ({ href: abs(l.getAttribute('href')), sizes: l.getAttribute('sizes'), rel: l.getAttribute('rel') }))
            .filter((i) => i.href);
          const theme = document.querySelector('meta[name="theme-color" i]');
          const appName = document.querySelector('meta[name="application-name" i]');
          return JSON.stringify({
            url: location.href, title: document.title,
            manifest: manifest ? abs(manifest.getAttribute('href')) : null,
            manifestCredentials: manifest ? manifest.crossOrigin === 'use-credentials' : false,
            icons, themeColor: theme ? theme.content : null, applicationName: appName ? appName.content : null,
          });
        })()
        """
}

/// The launcher bundle each app gets in the apps folder: an app whose executable just asks Kite to
/// open `kite-app://<id>`, with the app's icon. Chrome writes the same kind of shim to
/// ~/Applications/Chrome Apps.localized.
public enum WebAppShim {
    /// The folder's name under ~/Applications.
    public static let folderName = "Kite Apps"
    public static let executableName = "launcher"
    public static let iconFileName = "app.icns"

    /// The bundle's file name for an app called `name`: path separators and leading dots replaced,
    /// at most 64 characters, and " 2", " 3"… when `taken` already has it (case-insensitively).
    public static func bundleName(for name: String, taken: Set<String> = []) -> String {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        base = String(base.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Web App" }
        let lowered = Set(taken.map { $0.lowercased() })
        var candidate = base + ".app"
        var n = 2
        while lowered.contains(candidate.lowercased()) {
            candidate = "\(base) \(n).app"
            n += 1
        }
        return candidate
    }

    public static func bundleIdentifier(appID: String, kiteBundleID: String) -> String { "\(kiteBundleID).app.\(appID)" }

    /// Contents/Info.plist's keys. LSUIElement keeps the launcher, which exits at once, out of the Dock.
    public static func infoPlist(for app: WebApp, kiteBundleID: String) -> [String: Any] {
        [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": executableName,
            "CFBundleIconFile": iconFileName,
            "CFBundleIdentifier": bundleIdentifier(appID: app.id, kiteBundleID: kiteBundleID),
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": app.name,
            "CFBundleDisplayName": app.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            "KiteAppID": app.id,
            "KiteAppURL": WebApps.launchURL(for: app.id).absoluteString,
            "KiteAppStartURL": app.startURL.absoluteString,
        ]
    }

    /// Contents/MacOS/launcher: opens the app's kite-app:// URL in Kite (by bundle id, so it finds Kite
    /// wherever it's installed).
    public static func launcherScript(appID: String, kiteBundleID: String) -> String {
        precondition(WebApps.isAppID(appID))
        let safeBundleID = kiteBundleID.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        return """
            #!/bin/sh
            # Kite web app launcher: opens this app in Kite.
            exec /usr/bin/open -b '\(safeBundleID)' '\(WebApps.launchURL(for: appID).absoluteString)'

            """
    }
}
