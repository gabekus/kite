import Foundation

/// Arc Max's Instant Links: ⇧⏎ on a web search in the command bar opens the top result
/// instead of the results page, and a query asking for several things opens one tab each.
///
/// Arc's mechanism (1.171 binary, see docs/arc-visual-spec.md): a language model turns
/// what was typed into a title, one or more search queries and a format (tab, folder or
/// split); each query is searched on Google in hidden web content and its first result is
/// opened. Kite does the same with its own Claude (`claude -p`) and a hidden web view.
public enum InstantLinks {
    /// How Arc lays the results out: plain tabs unless the input asked for a folder or a split.
    public enum Format: String, Codable, Sendable {
        case tab, folder, split
    }

    /// What the model returns for one input.
    public struct Plan: Equatable, Codable, Sendable {
        public var title: String
        public var queries: [String]
        public var format: Format

        public init(title: String, queries: [String], format: Format = .tab) {
            self.title = title
            self.queries = queries
            self.format = format
        }

        /// Without a model: the input itself is the one query.
        public static func fallback(for input: String) -> Plan {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return Plan(title: text, queries: [text])
        }
    }

    /// The most results Kite opens for one input (Arc's split view holds 4 panes; more tabs than
    /// this from one keystroke would be a mistake).
    public static let maxQueries = 6

    /// Kite's instructions for the model. Same output schema as Arc's (title, queries, format);
    /// the wording is Kite's own.
    public static let systemPrompt = """
        You turn what someone typed into a browser's address bar into Google search queries. Their browser \
        will open the top result of each query directly, so each query must find one specific page.

        Reply with JSON only, no prose and no code fence:
        {"title": String, "queries": [String], "format": "tab" | "folder" | "split"}

        - title: a short, readable name for what they're looking for.
        - queries: precise Google queries that avoid SEO spam. Use one query unless the input explicitly asks \
        for more than one thing ("x and y", "a, b and c"); then one query per thing. Add site:domain when they \
        name a site (e.g. "amazon iphone chargers" -> "iphone chargers site:amazon.com").
        - format: "folder" only if they explicitly ask for a folder, "split" only if they explicitly ask for a \
        split view or say "on the left"/"on the right". Otherwise "tab".
        """

    /// Reads the model's reply: the first JSON object in it, tolerating a code fence and trailing commas.
    /// Nil when there's no usable query.
    public static func plan(from reply: String, input: String) -> Plan? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return nil }
        var json = String(reply[start...end])
        // Trailing commas before } or ].
        json = json.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        struct Loose: Decodable {
            var title: String?
            var queries: [String]?
            var format: String?
        }
        guard let loose = try? JSONDecoder().decode(Loose.self, from: Data(json.utf8)) else { return nil }
        let queries = (loose.queries ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !queries.isEmpty else { return nil }
        let title = loose.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Plan(
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? input.trimmingCharacters(in: .whitespacesAndNewlines),
            queries: Array(queries.prefix(maxQueries)),
            format: loose.format.flatMap { Format(rawValue: $0.lowercased()) } ?? .tab
        )
    }

    /// The Google results page Kite reads a query's top result from.
    public static func googleURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// Arc reads Google's organic results from `#search a`.
    public static let resultSelector = "#search a"

    /// The first real result among the links of a Google results page, in page order:
    /// Google's /url?q= redirects unwrapped, Google's own pages (more results, images,
    /// translations, cached copies) and non-web links skipped. An opaque Google redirect
    /// (/goto?url=…) comes back as it is, for the caller to follow (`isGoogleRedirect`).
    public static func topResult(fromLinks links: [String]) -> URL? {
        for link in links {
            guard var url = URL(string: link) else { continue }
            if isGoogle(url.host()), url.path() == "/url",
               let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                   .first(where: { $0.name == "q" || $0.name == "url" })?.value,
               let unwrapped = URL(string: target), unwrapped.host() != nil {
                url = unwrapped
            }
            guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  let host = url.host() else { continue }
            if isGoogleRedirect(url) { return url }
            if isGoogle(host) || host.hasSuffix("googleusercontent.com") { continue }
            return url
        }
        return nil
    }

    /// A Google link that only redirects to a result, which has to be followed to learn where it goes.
    public static func isGoogleRedirect(_ url: URL) -> Bool {
        isGoogle(url.host()) && ["/goto", "/url"].contains(url.path())
    }

    static func isGoogle(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let parts = host.split(separator: ".")
        // google.com, www.google.co.uk, maps.google.com, but not googleblog.com.
        guard let i = parts.firstIndex(of: "google") else { return false }
        let suffix = parts[(i + 1)...]
        return !suffix.isEmpty && suffix.count <= 2 && suffix.allSatisfy { $0.count <= 3 }
    }

    /// Instant Links needs a search, not an address: a URL opens as usual.
    public static func applies(to input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && !URLInput.looksLikeURL(text)
    }
}

extension BrowserState {
    /// Opens Instant Links' results in the current space, in the order the queries came, and
    /// selects the first: as tabs, as one split view (up to its 4 panes; the rest as tabs), or
    /// in a new folder named after the plan. Returns the new tabs' IDs.
    @discardableResult
    public mutating func openInstantLinks(_ urls: [URL], title: String, format: InstantLinks.Format, now: Date = Date()) -> [UUID] {
        guard !urls.isEmpty else { return [] }
        let space = selectedSpace.id
        // New tabs go to the top of the list, so open the last one first.
        let ids = urls.reversed().map { openTab(url: $0, in: space, select: false, now: now) }.reversed() as [UUID]
        let s = selectedSpaceIndex
        switch format {
        case .tab:
            break
        case .split where ids.count > 1:
            spaces[s].splits.append(SplitView(tabIDs: Array(ids.prefix(SplitView.maxPanes))))
        case .split:
            break
        case .folder:
            let folder = createFolder(name: title, inSpace: s)
            for id in ids { moveTab(id, toFolder: folder) }
        }
        select(tab: ids[0], now: now)
        return ids
    }
}
