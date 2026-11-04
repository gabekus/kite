import Foundation
import Testing
@testable import KiteCore

@Suite struct FavoritePreviewsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func picksThePreviewFromTheFavoritesURL() {
        func kind(_ s: String) -> FavoritePreviews.Kind? { FavoritePreviews.kind(for: URL(string: s)) }
        #expect(kind("https://mail.google.com/mail/u/0/#inbox") == .gmail(account: 0))
        #expect(kind("https://mail.google.com/mail/u/2/") == .gmail(account: 2))
        #expect(kind("https://mail.google.com/") == .gmail(account: 0))
        #expect(kind("https://calendar.google.com/calendar/u/0/r") == .calendar)
        #expect(kind("https://calendar.notion.so/") == .calendar)
        #expect(kind("https://www.notion.so/Roadmap-1") == .recents(.notion))
        #expect(kind("https://linear.app/team/issue/ABC-1") == .recents(.linear))
        #expect(kind("https://www.figma.com/files") == .recents(.figma))
        #expect(kind("https://acme.atlassian.net/wiki/home") == .recents(.confluence))
        #expect(kind("https://acme.atlassian.net/jira/your-work") == nil)
        #expect(kind("https://www.wikipedia.org/") == nil)
        #expect(kind("about:blank") == nil)
    }

    @Test func listsUnreadMailNewestFirst() {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed version="0.3" xmlns="http://purl.org/atom/ns#">
        <title>Gmail - Inbox for test@example.com</title>
        <fullcount>2</fullcount>
        <entry>
        <title>Older</title>
        <summary>First</summary>
        <link rel="alternate" href="http://mail.google.com/mail?account_id=test@example.com&amp;message_id=1&amp;view=conv&amp;extsrc=atom" type="text/html" />
        <issued>2027-01-15T08:00:00Z</issued>
        <author><name>Avery Stone</name><email>avery@example.com</email></author>
        </entry>
        <entry>
        <title></title>
        <summary>Second</summary>
        <link rel="alternate" href="http://mail.google.com/mail?account_id=test@example.com&amp;message_id=2&amp;view=conv&amp;extsrc=atom" type="text/html" />
        <issued>2027-01-15T09:00:00Z</issued>
        <author><name></name><email>jordan@example.com</email></author>
        </entry>
        </feed>
        """
        let items = FavoritePreviews.emails(VerificationCodes.parseGmailFeed(Data(feed.utf8)))
        #expect(items.map(\.title) == ["jordan@example.com", "Avery Stone"])
        #expect(items.map(\.subtitle) == ["(no subject)", "Older"])
        #expect(items.map(\.detail) == ["Second", "First"])
        #expect(items.last?.url?.absoluteString
            == "https://mail.google.com/mail?account_id=test@example.com&message_id=1&view=conv&extsrc=atom")
    }

    @Test func listsRecentPagesOnTheSite() {
        let entries = [
            HistoryEntry(url: URL(string: "https://www.notion.so/Roadmap-1")!, title: "Roadmap | Notion", lastVisit: now),
            HistoryEntry(url: URL(string: "https://www.notion.so/login")!, title: "Log in | Notion", lastVisit: now),
            HistoryEntry(url: URL(string: "https://www.notion.so/")!, title: "Notion", lastVisit: now),
            HistoryEntry(url: URL(string: "https://acme.notion.site/Notes-2")!, title: "Notes", lastVisit: now.addingTimeInterval(60)),
            HistoryEntry(url: URL(string: "https://www.wikipedia.org/wiki/Notion")!, title: "Notion - Wikipedia", lastVisit: now),
        ]
        let items = FavoritePreviews.recentPages(entries, site: .notion)
        #expect(items.map(\.title) == ["Notes", "Roadmap"])
    }

    @Test func listsUpcomingEventsWithTheirCalls() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let locale = Locale(identifier: "en_US")
        let events = [
            FavoritePreviews.Event(id: "past", title: "Done", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), isAllDay: false),
            FavoritePreviews.Event(id: "allday", title: "Holiday", start: now, end: now.addingTimeInterval(86400), isAllDay: true),
            FavoritePreviews.Event(id: "next", title: "Sync", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(3600), isAllDay: false,
                                   text: ["Join: https://meet.google.com/abc-defg-hij"]),
            FavoritePreviews.Event(id: "now", title: "", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600), isAllDay: false,
                                   text: ["https://acme.zoom.us/j/123456?pwd=x"]),
        ]
        let items = FavoritePreviews.events(events, now: now, calendar: calendar, locale: locale)
        #expect(items.map(\.id) == ["now", "next"])
        #expect(items[0].title == "Untitled event")
        #expect(items[0].subtitle.hasPrefix("Now · "))
        #expect(items[0].joinURL?.host() == "acme.zoom.us")
        #expect(items[1].joinURL?.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test func oldMailShowsLoadingAndTheReaderWaitsLongerInFront() {
        #expect(FavoritePreviews.showsCached(age: 0))
        #expect(FavoritePreviews.showsCached(age: FavoritePreviews.maxShownAge))
        #expect(!FavoritePreviews.showsCached(age: FavoritePreviews.maxShownAge + 1))
        #expect(FavoritePreviews.readerIdleTimeout(appActive: true) == 600)
        #expect(FavoritePreviews.readerIdleTimeout(appActive: false) == 120)
    }
}
