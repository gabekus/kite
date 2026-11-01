import Foundation
import Testing
@testable import KiteCore

@Suite struct ArchiveTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        return calendar
    }

    /// Friday, 15 January 2027, 06:40 UTC.
    private let now = Date(timeIntervalSince1970: 1_799_995_200)

    private func state() -> BrowserState {
        BrowserState(spaces: [
            Space(name: "Home", icon: "🏠", theme: Theme.presets[0]),
            Space(name: "Work", icon: "💼", theme: Theme.presets[1]),
        ])
    }

    private func archive(_ state: inout BrowserState, _ url: String, title: String = "", space: Int = 0,
                         ago: TimeInterval, reason: ArchiveReason = .manual) -> UUID {
        let tab = BrowserTab(url: URL(string: url), title: title)
        state.appendToArchive([ClosedTab(tab: tab, spaceID: state.spaces[space].id, index: 0)],
                              reason: reason, now: now.addingTimeInterval(-ago))
        return tab.id
    }

    @Test func closingAndAutoArchivingStampDateAndReason() {
        var state = state()
        let space = state.spaces[0].id
        let closed = state.openTab(url: URL(string: "https://a.example"), in: space, select: false)
        state.close(tab: closed)
        let stale = state.openTab(url: URL(string: "https://b.example"), in: space, select: false)
        state.update(tab: stale) { $0.lastActiveAt = now.addingTimeInterval(-7200) }
        state.archiveStaleTabs(olderThan: 3600, now: now)
        #expect(state.archived.map(\.reason) == [.manual, .auto])
        #expect(state.archived.last?.archivedAt == now)
        #expect(state.archived.allSatisfy { $0.archivedAt != nil })
    }

    @Test func sectionsAreNewestFirstInArcsBuckets() {
        var state = state()
        let today = archive(&state, "https://today.example", ago: 3600)
        let yesterday = archive(&state, "https://yesterday.example", ago: 86_400)
        // Tuesday of the same week.
        let tuesday = archive(&state, "https://tuesday.example", ago: 3 * 86_400)
        let december = archive(&state, "https://december.example", ago: 40 * 86_400)
        let sections = state.archiveSections(now: now, calendar: utc)
        #expect(sections.map(\.bucket).prefix(3) == [.today, .yesterday, .earlierThisWeek])
        #expect(sections.map { $0.items.map(\.tab.id) } == [[today], [yesterday], [tuesday], [december]])
        #expect(sections[3].title(locale: Locale(identifier: "en_US"), calendar: utc) == "December 2026")
        #expect(sections[0].title() == "Today")
    }

    @Test func filtersBySpaceReasonAndQuery() {
        var state = state()
        let home = archive(&state, "https://swift.org", title: "Swift", ago: 60)
        let work = archive(&state, "https://linear.app", title: "Linear", space: 1, ago: 60, reason: .auto)
        func ids(_ filter: ArchiveFilter) -> [UUID] {
            state.archiveSections(filter, now: now, calendar: utc).flatMap { $0.items.map(\.tab.id) }
        }
        #expect(ids(ArchiveFilter(spaceID: state.spaces[1].id)) == [work])
        #expect(ids(ArchiveFilter(reason: .manual)) == [home])
        #expect(ids(ArchiveFilter(reason: .auto)) == [work])
        #expect(ids(ArchiveFilter(query: "SWIFT")) == [home])
        #expect(ids(ArchiveFilter(query: "linear.app")) == [work])
        #expect(ids(ArchiveFilter(query: "nothing")).isEmpty)
    }

    @Test func legacyEntriesWithoutDateOrReasonStillShow() throws {
        var state = state()
        let tab = BrowserTab(url: URL(string: "https://old.example"), lastActiveAt: now.addingTimeInterval(-60))
        state.archived = [ClosedTab(tab: tab, spaceID: state.spaces[0].id, index: 0)]
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: data)
        let sections = decoded.archiveSections(ArchiveFilter(reason: .manual), now: now, calendar: utc)
        #expect(sections.first?.bucket == .today)
        #expect(sections.first?.items.map(\.tab.id) == [tab.id])
    }

    @Test func restorePutsTheTabBackInItsSpaceWithoutSelectingIt() {
        var state = state()
        let work = state.spaces[1].id
        let kept = state.openTab(url: URL(string: "https://kept.example"), in: work, select: true)
        let gone = state.openTab(url: URL(string: "https://gone.example"), in: work, select: false)
        state.close(tab: gone)
        state.selectSpace(state.spaces[0].id)
        #expect(state.restoreArchived(gone, now: now) == work)
        #expect(state.spaces[1].tabs.map(\.id).contains(gone))
        #expect(state.spaces[1].selectedTabID == kept)
        #expect(state.selectedSpaceID == state.spaces[0].id)
        #expect(state.tab(gone)?.lastActiveAt == now)
        #expect(state.archived.isEmpty && state.recentlyClosed.isEmpty)
        // Already open: a second restore does nothing.
        #expect(state.restoreArchived(gone) == nil)
    }

    @Test func restoreFromADeletedSpaceGoesToTheCurrentOne() {
        var state = state()
        let id = archive(&state, "https://x.example", space: 1, ago: 60)
        state.deleteSpace(state.spaces[1].id)
        #expect(state.restoreArchived(id) == state.spaces[0].id)
        #expect(state.spaces[0].tabs.map(\.id) == [id])
    }

    @Test func deleteAndClear() {
        var state = state()
        let a = archive(&state, "https://a.example", ago: 60)
        let b = archive(&state, "https://b.example", ago: 60)
        state.deleteArchived([a])
        #expect(state.archived.map(\.tab.id) == [b])
        #expect(state.clearArchive() == 1)
        #expect(state.archived.isEmpty)
    }

    @Test func archivePageURL() {
        #expect(InternalPage(URL(string: "kite://archive")) == .archive)
        #expect(InternalPage.archive.url.absoluteString == "kite://archive")
        #expect(InternalPage.archive.title == "Archive")
    }
}
