import Foundation

/// Arc's Site Search: type a site's shortcut in the command bar, press Tab, and
/// the query goes to that site's search page instead of the default engine.
/// Same model as Chromium's search-engine shortcuts, so Arc's import directly.
public struct SiteSearch: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    /// Shown in the command bar: "Search YouTube".
    public var name: String
    /// What you type before Tab, e.g. "yt" or "youtube.com".
    public var shortcut: String
    /// The search URL with `%s` where the query goes.
    public var urlTemplate: String
    /// The chip's colour as "RRGGBB": set for Arc's defaults; other sites use their favicon's colour.
    public var color: String?

    public init(id: UUID = UUID(), name: String, shortcut: String, urlTemplate: String, color: String? = nil) {
        self.id = id
        self.name = name
        self.shortcut = shortcut
        self.urlTemplate = urlTemplate
        self.color = color
    }

    /// From a Chromium search engine (Arc's Site Search settings). Chromium writes
    /// the query as {searchTerms}; other {…} parameters need Chromium's own
    /// substitution, so those engines are skipped.
    public init?(chromiumName name: String, keyword: String, url: String) {
        let template = url.replacingOccurrences(of: "{searchTerms}", with: "%s")
        guard !keyword.isEmpty, template.contains("%s"), !template.contains("{"),
              let scheme = URL(string: template.replacingOccurrences(of: "%s", with: "q"))?.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        self.init(name: name, shortcut: keyword, urlTemplate: template)
    }

    public func url(for query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: URLInput.unreserved) ?? query
        return URL(string: urlTemplate.replacingOccurrences(of: "%s", with: encoded))
    }

    /// The site search a command-bar entry would switch to on Tab: an exact
    /// shortcut first, then a shortcut or name the text starts.
    public static func match(_ input: String, in sites: [SiteSearch]) -> SiteSearch? {
        let text = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if let exact = sites.first(where: { $0.shortcut.lowercased() == text }) { return exact }
        guard text.count >= 2 else { return nil }
        return sites.first { site in
            site.shortcut.lowercased().hasPrefix(text) || site.name.lowercased().hasPrefix(text)
        }
    }
}

extension SiteSearch {
    /// The Site Searches Arc 1.169 seeds into every profile, in Arc's order. Read from
    /// Arc's seeding code (keyword = the site's domain, and the chip's brand colour);
    /// the URLs are the sites' own public search pages.
    public static let arcDefaults: [SiteSearch] = [
        ("Google Drive", "drive.google.com", "https://drive.google.com/drive/search?q=%s", "0F9D58"),
        ("Gmail", "mail.google.com", "https://mail.google.com/mail/ca/u/0/#apps/%s", "D44638"),
        ("Google Maps", "maps.google.com", "https://www.google.com/maps/search/%s", "FBBC05"),
        ("Google Calendar", "calendar.google.com", "https://calendar.google.com/calendar/u/0/r/search?q=%s", "9C27B0"),
        ("Google Docs", "docs.google.com", "https://docs.google.com/document/u/0/?q=%s", "4285F4"),
        ("Dropbox", "dropbox.com", "https://www.dropbox.com/search/personal?&query=%s", "007EE5"),
        ("Amazon", "amazon.com", "https://www.amazon.com/s?k=%s", "FF9900"),
        ("GitHub", "github.com", "https://github.com/search?q=%s", "743FC7"),
        ("Figma", "figma.com", "https://www.figma.com/files/search?q=%s", "F24E1E"),
        ("X", "x.com", "https://x.com/search?q=%s", "000000"),
        ("X", "twitter.com", "https://twitter.com/search?q=%s", "000000"),
        ("YouTube", "youtube.com", "https://www.youtube.com/results?search_query=%s", "FF0000"),
        ("Wikipedia", "wikipedia.org", "https://wikipedia.org/w/index.php?search=%s", "FF4500"),
        ("Reddit", "reddit.com", "https://www.reddit.com/search/?q=%s", "FF4500"),
        ("SoundCloud", "soundcloud.com", "https://soundcloud.com/search?q=%s", "F85216"),
        ("Asana", "asana.com", "https://app.asana.com/0/search?q=%s", "F06A6A"),
        ("LinkedIn", "linkedin.com", "https://linkedin.com/search/results/all/?keywords=%s", "0B66C2"),
        ("Apple Music", "music.apple.com", "https://music.apple.com/us/search?term=%s", "FA2A44"),
        ("Spotify", "spotify.com", "https://open.spotify.com/search/%s", "1DB954"),
    ].map { SiteSearch(name: $0, shortcut: $1, urlTemplate: $2, color: $3) }
}

extension BrowserState {
    /// Bumped when `SiteSearch.arcDefaults` gains entries or fields existing sessions should get.
    /// 2: the defaults' chip colours.
    static let siteSearchDefaultsVersion = 2

    /// Adds Arc's default Site Searches that aren't there yet. One the user already
    /// has (same shortcut, e.g. imported from Arc) is left as it is.
    mutating func seedDefaultSiteSearches() {
        guard siteSearchDefaultsSeeded < Self.siteSearchDefaultsVersion else { return }
        if siteSearchDefaultsSeeded < 1 {
            let existing = Set(siteSearches.map { $0.shortcut.lowercased() })
            siteSearches += SiteSearch.arcDefaults.filter { !existing.contains($0.shortcut.lowercased()) }
        }
        // Defaults seeded before they had colours. One the user changed keeps its favicon colour.
        for i in siteSearches.indices where siteSearches[i].color == nil {
            let site = siteSearches[i]
            siteSearches[i].color = SiteSearch.arcDefaults.first {
                $0.shortcut == site.shortcut && $0.name == site.name && $0.urlTemplate == site.urlTemplate
            }?.color
        }
        siteSearchDefaultsSeeded = Self.siteSearchDefaultsVersion
    }

    /// Adds imported shortcuts; one with the same shortcut as an existing entry replaces it.
    public mutating func mergeSiteSearches(_ imported: [SiteSearch]) {
        for site in imported {
            if let i = siteSearches.firstIndex(where: { $0.shortcut.lowercased() == site.shortcut.lowercased() }) {
                siteSearches[i] = SiteSearch(id: siteSearches[i].id, name: site.name, shortcut: site.shortcut, urlTemplate: site.urlTemplate, color: site.color)
            } else {
                siteSearches.append(site)
            }
        }
    }
}
