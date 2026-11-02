import Foundation

/// Arc's favorite previews (its `Previews` module, `AppPreviews`, `StandardPreviewView`): hover a
/// Gmail, Google Calendar, Notion, Linear, Figma or Confluence favorite and a card beside the
/// sidebar lists unread mail, upcoming events or recent pages, with a button to start a new one.
/// Sources and numbers are in docs/arc-visual-spec.md ("Favorite previews").
public enum FavoritePreviews {
    /// Settings key. Arc's is `gmailPreviewEnabled` (unset in Gabe's Arc, so on).
    public static let enabledKey = "favoritePreviewsEnabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Arc's `PreviewType`s: `gmail`, `googleCalendar` and `recentPages` (by domain). Arc also has
    /// Outlook mail and calendar through a Microsoft sign-in, which Kite doesn't.
    public enum Kind: Hashable, Sendable {
        /// Unread mail for Gmail account `account` (the `N` in `/mail/u/N/`).
        case gmail(account: Int)
        case calendar
        case recents(RecentsSite)
    }

    /// The sites Arc lists recent pages for (`RecentPagesFetcher`, by domain from history).
    public enum RecentsSite: String, Hashable, Sendable, CaseIterable {
        case notion, linear, figma, confluence

        /// Hosts whose history pages count.
        public func matches(host: String) -> Bool {
            let host = host.lowercased()
            func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
            switch self {
            case .notion: return under("notion.so") || under("notion.site") || under("notion.com")
            case .linear: return under("linear.app")
            case .figma: return under("figma.com")
            case .confluence: return under("atlassian.net") && !host.hasPrefix("id.")
            }
        }
    }

    /// The preview a favorite pinned to `url` gets, if any.
    public static func kind(for url: URL?) -> Kind? {
        guard let url, let host = url.host()?.lowercased() else { return nil }
        if host == "mail.google.com" { return .gmail(account: gmailAccount(in: url)) }
        if host == "calendar.google.com" || host == "calendar.notion.so" || host == "calendar.notion.com" { return .calendar }
        if host == "confluence.new" { return .recents(.confluence) }
        if host.hasSuffix("atlassian.net"), !url.path.contains("/wiki") { return nil }
        return RecentsSite.allCases.first { $0.matches(host: host) }.map(Kind.recents)
    }

    /// The Gmail account a URL is for: `/mail/u/1/...` is the second signed-in account.
    public static func gmailAccount(in url: URL) -> Int {
        let parts = url.path.split(separator: "/")
        if let u = parts.firstIndex(of: "u"), u + 1 < parts.count, let n = Int(parts[u + 1]) { return n }
        return 0
    }

    /// Each preview's empty and signed-out text, from Arc's binary (`StandardPreviewConfiguration`,
    /// FUN_100098xxx). It also names a header ("Unread", "Upcoming", "Recents") and a + button
    /// ("New Email" to `/#compose`…), which Arc's Gmail card didn't show when measured, so Kite leaves
    /// them out.
    public struct Configuration: Equatable, Sendable {
        public var emptyText: String
        public var signedOutText: String?
        public var signInTitle: String?
    }

    public static func configuration(for kind: Kind) -> Configuration {
        switch kind {
        case .gmail:
            return Configuration(emptyText: "No unread emails, you can exhale! 🍃",
                                 signedOutText: "Sign in to your Email to see messages at a glance.", signInTitle: "Sign In")
        case .calendar:
            return Configuration(emptyText: "No upcoming events",
                                 signedOutText: "See upcoming meetings and join video calls instantly with the Calendar Preview.",
                                 signInTitle: "Connect Calendar")
        case .recents(let site):
            let empty = switch site {
            case .notion: "Recent Notion docs appear here."
            case .linear: "Recent Linear projects and issues appear here."
            case .figma: "Recent Figma files appear here."
            case .confluence: "Recent Confluence pages appear here."
            }
            return Configuration(emptyText: empty, signedOutText: nil, signInTitle: nil)
        }
    }

    // MARK: Rows

    /// One line of the card: an email, an event or a page.
    public struct Item: Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var subtitle: String
        /// An email's opening text (the feed's summary), nil otherwise.
        public var detail: String?
        public var date: Date?
        public var url: URL?
        /// An event's video call.
        public var joinURL: URL?

        public init(id: String, title: String, subtitle: String, detail: String? = nil, date: Date? = nil,
                    url: URL? = nil, joinURL: URL? = nil) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.detail = detail
            self.date = date
            self.url = url
            self.joinURL = joinURL
        }
    }

    /// What a preview shows.
    public enum Content: Equatable, Sendable {
        case loading
        case signedOut
        case items([Item])
    }

    /// Rows the card lists at most (it scrolls past what fits).
    public static let maxItems = 20

    /// Unread mail from Gmail's feed: newest first, the sender as the title, the subject under it, then
    /// the opening text.
    public static func emails(_ messages: [VerificationCodes.Message]) -> [Item] {
        messages.sorted { $0.date > $1.date }.prefix(maxItems).enumerated().map { i, message in
            let sender = message.senderName.isEmpty ? message.senderEmail : message.senderName
            let subject = message.subject.isEmpty ? "(no subject)" : message.subject
            return Item(id: message.link?.absoluteString ?? "\(i)", title: sender, subtitle: subject,
                        detail: message.snippet, date: message.date, url: message.link.map(secureGmailLink))
        }
    }

    /// The feed links to `http://mail.google.com/mail?account_id=…&message_id=…`; open it over https.
    static func secureGmailLink(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "http" else { return url }
        parts.scheme = "https"
        return parts.url ?? url
    }

    /// Recent pages on `site` from history, newest first, one per page (Arc's `RecentPagesFetcher`
    /// searches history by domain). Sign-in and home pages aren't documents, so they're left out.
    public static func recentPages(_ entries: some Sequence<HistoryEntry>, site: RecentsSite, limit: Int = 8) -> [Item] {
        entries
            .filter { entry in
                guard let host = entry.url.host(), site.matches(host: host) else { return false }
                let path = entry.url.path
                return path.count > 1 && !path.contains("login") && !path.contains("signup") && !entry.title.isEmpty
            }
            .sorted { $0.lastVisit > $1.lastVisit }
            .prefix(limit)
            .map { entry in
                Item(id: entry.url.absoluteString, title: tidy(entry.title, site: site), subtitle: "",
                     date: entry.lastVisit, url: entry.url)
            }
    }

    /// Drops the site's name from a page title ("Roadmap | Notion" → "Roadmap").
    static func tidy(_ title: String, site: RecentsSite) -> String {
        let names: [String] = switch site {
        case .notion: ["Notion"]
        case .linear: ["Linear"]
        case .figma: ["Figma"]
        case .confluence: ["Confluence"]
        }
        var title = title
        for name in names {
            for separator in [" | ", " – ", " — ", " - "] where title.hasSuffix(separator + name) {
                title = String(title.dropLast(separator.count + name.count))
            }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Events

    /// A calendar event, as the calendar reads it.
    public struct Event: Equatable, Sendable {
        public var id: String
        public var title: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        /// The event's link, location and notes, searched for a video call.
        public var text: [String]
        public var url: URL?

        public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool, text: [String] = [], url: URL? = nil) {
            self.id = id
            self.title = title
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.text = text
            self.url = url
        }
    }

    /// Timed events that haven't ended, soonest first: the title, and when it is under it.
    public static func events(_ events: [Event], now: Date = Date(), calendar: Calendar = .current,
                              locale: Locale = .current) -> [Item] {
        events
            .filter { !$0.isAllDay && $0.end > now }
            .sorted { $0.start < $1.start }
            .prefix(maxItems)
            .map { event in
                Item(id: event.id, title: event.title.isEmpty ? "Untitled event" : event.title,
                     subtitle: when(event, now: now, calendar: calendar, locale: locale), date: event.start,
                     url: event.url, joinURL: joinURL(in: event.text + [event.url?.absoluteString].compactMap { $0 }))
            }
    }

    /// "Now · 2:00 – 3:00 PM", "Today · 4:30 – 5:00 PM", "Tomorrow · 9:00 – 9:30 AM", "Mon, Nov 9 · …".
    static func when(_ event: Event, now: Date, calendar: Calendar, locale: Locale) -> String {
        let interval = DateIntervalFormatter()
        interval.calendar = calendar
        interval.timeZone = calendar.timeZone
        interval.locale = locale
        interval.dateStyle = .none
        interval.timeStyle = .short
        let times = interval.string(from: event.start, to: event.end)
        let day: String
        if event.start <= now {
            day = "Now"
        } else if calendar.isDate(event.start, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(event.start, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
            day = formatter.string(from: event.start)
        }
        return day + " · " + times
    }

    private static let callLink = try! NSRegularExpression(
        pattern: #"https://(?:meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}|[\w.-]*zoom\.us/(?:j|my|w)/[^\s<>"']+|teams\.microsoft\.com/l/meetup-join/[^\s<>"']+|[\w.-]*webex\.com/[^\s<>"']+|whereby\.com/[^\s<>"']+|around\.co/[^\s<>"']+)"#,
        options: [.caseInsensitive]
    )

    /// The first video call link (Meet, Zoom, Teams, Webex, Whereby, Around) in an event's text.
    public static func joinURL(in texts: [String]) -> URL? {
        for text in texts {
            let ns = text as NSString
            if let match = callLink.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return URL(string: ns.substring(with: match.range))
            }
        }
        return nil
    }
}
