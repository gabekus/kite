import Foundation

/// The search engine's own suggestions for what's typed in the command bar, as Arc shows them
/// (its `chromiumSearchSuggestion` results, from Chromium's search suggest provider) while
/// "Include search engine suggestions" is on.
public enum SearchSuggestions {
    /// Rows shown below the typed search.
    public static let limit = 4

    /// Whether to ask the engine about `text` at all: not for an empty field, a URL, a Site
    /// Search, or while the profile has suggestions off.
    public static func shouldFetch(_ text: String, settings: ProfileSettings, inSiteSearch: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return settings.includesSearchSuggestions && !inSiteSearch && !trimmed.isEmpty
            && !URLInput.looksLikeURL(trimmed)
    }

    /// The engine's suggest request for `query`. `template` replaces the engine's own URL
    /// (tests point it at a local fixture); `{searchTerms}` in it is the encoded query.
    public static func requestURL(for query: String, engine: SearchEngine, template: String? = nil) -> URL? {
        guard let template = template ?? engine.suggestTemplate else { return nil }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: URLInput.unreserved) ?? query
        return URL(string: template.replacingOccurrences(of: "{searchTerms}", with: encoded))
    }

    /// Reads the OpenSearch suggestions answer, `["query", ["one", "two", …], …]`, which
    /// Google, Bing and DuckDuckGo all send. Drops what was typed itself and repeats.
    public static func parse(_ data: Data, query: String) -> [String] {
        var body = data
        // Google can prefix its JSON with an XSSI guard line.
        if let text = String(data: data, encoding: .utf8), text.hasPrefix(")]}'") {
            body = Data(text.drop { $0 != "\n" }.utf8)
        }
        guard let array = try? JSONSerialization.jsonObject(with: body) as? [Any],
              array.count > 1, let list = array[1] as? [Any]
        else { return [] }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen: Set<String> = [typed]
        var result: [String] = []
        for case let item as String in list {
            let suggestion = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suggestion.isEmpty, seen.insert(suggestion.lowercased()).inserted else { continue }
            result.append(suggestion)
            if result.count == limit { break }
        }
        return result
    }
}

extension SearchEngine {
    /// The engine's suggest endpoint, as Chromium's built-in engines list it. Kagi only
    /// answers signed-in requests, so Kite has none for it.
    public var suggestTemplate: String? {
        switch self {
        case .google: "https://www.google.com/complete/search?client=chrome&q={searchTerms}"
        case .duckDuckGo: "https://duckduckgo.com/ac/?q={searchTerms}&type=list"
        case .bing: "https://www.bing.com/osjson.aspx?query={searchTerms}"
        case .kagi: nil
        }
    }
}
