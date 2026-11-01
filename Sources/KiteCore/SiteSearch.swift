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
    /// Chromium's `is_active`: an inactive shortcut stays saved (the search engines page lists it under
    /// "Inactive shortcuts") but Tab no longer enters it from the command bar (Arc's command bar state
    /// keeps only `activeSearchEngines`).
    public var isActive: Bool

    public init(id: UUID = UUID(), name: String, shortcut: String, urlTemplate: String, color: String? = nil,
                isActive: Bool = true) {
        self.id = id
        self.name = name
        self.shortcut = shortcut
        self.urlTemplate = urlTemplate
        self.color = color
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, shortcut, urlTemplate, color, isActive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        shortcut = try c.decode(String.self, forKey: .shortcut)
        urlTemplate = try c.decode(String.self, forKey: .urlTemplate)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(shortcut, forKey: .shortcut)
        try c.encode(urlTemplate, forKey: .urlTemplate)
        try c.encodeIfPresent(color, forKey: .color)
        if !isActive { try c.encode(isActive, forKey: .isActive) }
    }

    /// The search engines page's filter field: Chromium keeps an entry while its name, shortcut
    /// or URL contains the filter, ignoring case (`computeMatchingEngines_`); an empty filter keeps all.
    public func matchesFilter(_ filter: String) -> Bool {
        SiteSearch.matches(filter, [name, shortcut, urlTemplate])
    }

    public static func matches(_ filter: String, _ terms: [String]) -> Bool {
        let filter = filter.lowercased()
        guard !filter.isEmpty else { return true }
        return terms.contains { $0.lowercased().contains(filter) }
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

    /// The shortcuts Tab can enter from the command bar.
    public var activeSiteSearches: [SiteSearch] { siteSearches.filter(\.isActive) }

    /// The search engines page's Activate (on an inactive shortcut) and ⋯ › Deactivate.
    public mutating func setSiteSearch(_ id: UUID, active: Bool) {
        guard let i = siteSearches.firstIndex(where: { $0.id == id }) else { return }
        siteSearches[i].isActive = active
    }

    /// Adds imported shortcuts; one with the same shortcut as an existing entry replaces it.
    public mutating func mergeSiteSearches(_ imported: [SiteSearch]) {
        for site in imported {
            if let i = siteSearches.firstIndex(where: { $0.shortcut.lowercased() == site.shortcut.lowercased() }) {
                siteSearches[i] = SiteSearch(id: siteSearches[i].id, name: site.name, shortcut: site.shortcut, urlTemplate: site.urlTemplate,
                                             color: site.color, isActive: site.isActive)
            } else {
                siteSearches.append(site)
            }
        }
    }
}

/// The Add / Edit site search dialog on the search engines page (Settings › Profiles › Search
/// Settings…). Chromium's dialog has the same three fields: Name, Shortcut, and "URL with %s in
/// place of query".
public struct SiteSearchDraft: Equatable, Sendable {
    public var name: String
    public var shortcut: String
    public var urlTemplate: String

    public init(name: String = "", shortcut: String = "", urlTemplate: String = "") {
        self.name = name
        self.shortcut = shortcut
        self.urlTemplate = urlTemplate
    }

    public init(_ site: SiteSearch) {
        self.init(name: site.name, shortcut: site.shortcut, urlTemplate: site.urlTemplate)
    }

    public enum Problem: Equatable, Sendable {
        case emptyName, emptyShortcut, shortcutHasSpace, shortcutTaken(String), invalidURL

        public var message: String {
            switch self {
            case .emptyName: "Enter a name"
            case .emptyShortcut: "Enter a shortcut"
            case .shortcutHasSpace: "A shortcut can’t contain spaces"
            case .shortcutTaken(let name): "Already used by “\(name)”"
            case .invalidURL: "Enter a web address with %s where the query goes"
            }
        }
    }

    private var trimmed: (name: String, shortcut: String, url: String) {
        (name.trimmingCharacters(in: .whitespacesAndNewlines),
         shortcut.trimmingCharacters(in: .whitespacesAndNewlines),
         urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What's wrong with the draft, field by field (empty when it can be saved). `editing` is the
    /// entry being edited, which may keep its own shortcut.
    public func problems(in sites: [SiteSearch], editing: UUID? = nil) -> [Problem] {
        let (name, shortcut, url) = trimmed
        var problems: [Problem] = []
        if name.isEmpty { problems.append(.emptyName) }
        if shortcut.isEmpty {
            problems.append(.emptyShortcut)
        } else if shortcut.contains(where: \.isWhitespace) {
            problems.append(.shortcutHasSpace)
        } else if let other = sites.first(where: { $0.id != editing && $0.shortcut.lowercased() == shortcut.lowercased() }) {
            problems.append(.shortcutTaken(other.name))
        }
        let probe = URL(string: url.replacingOccurrences(of: "%s", with: "q"))
        if !url.contains("%s") || !["http", "https"].contains(probe?.scheme?.lowercased() ?? "") || probe?.host() == nil {
            problems.append(.invalidURL)
        }
        return problems
    }

    public func isValid(in sites: [SiteSearch], editing: UUID? = nil) -> Bool {
        problems(in: sites, editing: editing).isEmpty
    }
}

extension BrowserState {
    /// Adds a site search from the dialog. Nil (and nothing added) if the draft isn't valid.
    @discardableResult
    public mutating func addSiteSearch(_ draft: SiteSearchDraft) -> UUID? {
        guard draft.isValid(in: siteSearches) else { return nil }
        let site = SiteSearch(name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                              shortcut: draft.shortcut.trimmingCharacters(in: .whitespacesAndNewlines),
                              urlTemplate: draft.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines))
        siteSearches.append(site)
        return site.id
    }

    /// Saves an edit. A new URL drops the entry's brand colour, so its chip takes the new site's favicon colour.
    @discardableResult
    public mutating func updateSiteSearch(_ id: UUID, _ draft: SiteSearchDraft) -> Bool {
        guard let i = siteSearches.firstIndex(where: { $0.id == id }), draft.isValid(in: siteSearches, editing: id) else { return false }
        let url = draft.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if siteSearches[i].urlTemplate != url { siteSearches[i].color = nil }
        siteSearches[i].name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        siteSearches[i].shortcut = draft.shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        siteSearches[i].urlTemplate = url
        return true
    }

    public mutating func removeSiteSearch(_ id: UUID) {
        siteSearches.removeAll { $0.id == id }
    }
}
