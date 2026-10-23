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

extension BrowserState {
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
