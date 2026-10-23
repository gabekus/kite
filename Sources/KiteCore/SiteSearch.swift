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

    public init(id: UUID = UUID(), name: String, shortcut: String, urlTemplate: String) {
        self.id = id
        self.name = name
        self.shortcut = shortcut
        self.urlTemplate = urlTemplate
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
    /// Arc's seeding code (keyword = the site's domain); the URLs are the sites' own
    /// public search pages.
    public static let arcDefaults: [SiteSearch] = [
        ("Google Drive", "drive.google.com", "https://drive.google.com/drive/search?q=%s"),
        ("Gmail", "mail.google.com", "https://mail.google.com/mail/ca/u/0/#apps/%s"),
        ("Google Maps", "maps.google.com", "https://www.google.com/maps/search/%s"),
        ("Google Calendar", "calendar.google.com", "https://calendar.google.com/calendar/u/0/r/search?q=%s"),
        ("Google Docs", "docs.google.com", "https://docs.google.com/document/u/0/?q=%s"),
        ("Dropbox", "dropbox.com", "https://www.dropbox.com/search/personal?&query=%s"),
        ("Amazon", "amazon.com", "https://www.amazon.com/s?k=%s"),
        ("GitHub", "github.com", "https://github.com/search?q=%s"),
        ("Figma", "figma.com", "https://www.figma.com/files/search?q=%s"),
        ("X", "x.com", "https://x.com/search?q=%s"),
        ("X", "twitter.com", "https://twitter.com/search?q=%s"),
        ("YouTube", "youtube.com", "https://www.youtube.com/results?search_query=%s"),
        ("Wikipedia", "wikipedia.org", "https://wikipedia.org/w/index.php?search=%s"),
        ("Reddit", "reddit.com", "https://www.reddit.com/search/?q=%s"),
        ("SoundCloud", "soundcloud.com", "https://soundcloud.com/search?q=%s"),
        ("Asana", "asana.com", "https://app.asana.com/0/search?q=%s"),
        ("LinkedIn", "linkedin.com", "https://linkedin.com/search/results/all/?keywords=%s"),
        ("Apple Music", "music.apple.com", "https://music.apple.com/us/search?term=%s"),
        ("Spotify", "spotify.com", "https://open.spotify.com/search/%s"),
    ].map { SiteSearch(name: $0, shortcut: $1, urlTemplate: $2) }
}

extension BrowserState {
    /// Bumped when `SiteSearch.arcDefaults` gains entries existing sessions should get.
    static let siteSearchDefaultsVersion = 1

    /// Adds Arc's default Site Searches that aren't there yet. One the user already
    /// has (same shortcut, e.g. imported from Arc) is left as it is.
    mutating func seedDefaultSiteSearches() {
        guard siteSearchDefaultsSeeded < Self.siteSearchDefaultsVersion else { return }
        let existing = Set(siteSearches.map { $0.shortcut.lowercased() })
        siteSearches += SiteSearch.arcDefaults.filter { !existing.contains($0.shortcut.lowercased()) }
        siteSearchDefaultsSeeded = Self.siteSearchDefaultsVersion
    }

    /// Adds imported shortcuts; one with the same shortcut as an existing entry replaces it.
    public mutating func mergeSiteSearches(_ imported: [SiteSearch]) {
        for site in imported {
            if let i = siteSearches.firstIndex(where: { $0.shortcut.lowercased() == site.shortcut.lowercased() }) {
                siteSearches[i] = SiteSearch(id: siteSearches[i].id, name: site.name, shortcut: site.shortcut, urlTemplate: site.urlTemplate)
            } else {
                siteSearches.append(site)
            }
        }
    }
}
