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

    @Test func claudeFolderArchivesStaleTabsAndGoesWhenEmpty() throws {
        var state = state()
        let work = state.spaces[1].id
        let made = state.claudeFolder(inSpace: work)
        let folder = try #require(made)
        let again = state.claudeFolder(inSpace: work)
        #expect(again == folder)
        #expect(state.spaces.count == 2)
        let stale = state.openTab(url: URL(string: "https://jlcpcb.example"), in: work, select: false)
        let fresh = state.openTab(url: URL(string: "https://eink.example"), in: work, select: false)
        _ = state.moveTab(stale, toFolder: folder)
        _ = state.moveTab(fresh, toFolder: folder)
        state.update(tab: stale) { $0.lastActiveAt = now.addingTimeInterval(-7200) }
        state.update(tab: fresh) { $0.lastActiveAt = now }
        // An ordinary folder's stale tabs stay put.
        let kept = state.createFolder(name: "Parts", inSpace: 1)
        let old = state.openTab(url: URL(string: "https://kept.example"), in: work, select: false)
        _ = state.moveTab(old, toFolder: kept)
        state.update(tab: old) { $0.lastActiveAt = now.addingTimeInterval(-7200) }

        state.archiveStaleTabs(olderThan: 3600, now: now)
        #expect(state.archived.map(\.tab.id) == [stale])
        #expect(state.archived.last?.spaceID == work)
        #expect(state.folder(matching: folder.uuidString)?.folder.items.tabs.map(\.id) == [fresh])
        #expect(state.tab(old) != nil)

        state.update(tab: fresh) { $0.lastActiveAt = now.addingTimeInterval(-7200) }
        state.archiveStaleTabs(olderThan: 3600, now: now)
        #expect(state.folder(matching: folder.uuidString) == nil)
        #expect(state.folder(matching: kept.uuidString) != nil)
    }

    @Test func eachTaskGetsItsOwnFolderInsideTheClaudeFolder() throws {
        var state = state()
        let work = state.spaces[1].id
        let made = (state.claudeTaskFolder(named: "Source the parts", inSpace: work),
                    state.claudeTaskFolder(named: "Is this open source?", inSpace: work))
        let first = try #require(made.0), second = try #require(made.1)
        let claude = try #require(state.spaces[1].pinnedItems.compactMap { item -> TabFolder? in
            if case .folder(let folder) = item { return folder }
            return nil
        }.first)
        #expect(state.spaces.count == 2)
        #expect(claude.name == "Claude" && claude.ephemeral == true)
        #expect(claude.items.map(\.id) == [first, second])

        let a = state.openTab(url: URL(string: "https://jlcpcb.example"), in: work, select: false)
        let b = state.openTab(url: URL(string: "https://eink.example"), in: work, select: false)
        _ = state.moveTab(a, toFolder: first)
        _ = state.moveTab(b, toFolder: second)
        state.update(tab: a) { $0.lastActiveAt = now.addingTimeInterval(-7200) }
        state.update(tab: b) { $0.lastActiveAt = now }
        state.archiveStaleTabs(olderThan: 3600, now: now)
        #expect(state.folder(matching: first.uuidString) == nil)
        #expect(state.folder(matching: second.uuidString) != nil)

        // Clearing the last task's folder takes the Claude folder with it.
        state.removeFolder(second)
        #expect(state.spaces[1].pinnedItems.isEmpty)
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

    @Test func littleKitePagesGetArcsLittleArcFilterAndRestoreToTheCurrentSpace() throws {
        var state = state()
        let home = archive(&state, "https://swift.org", title: "Swift", ago: 60)
        state.selectSpace(state.spaces[1].id)
        let archived = state.archiveLittleKite(url: URL(string: "https://news.example/a"), title: "A", reason: .auto, now: now)
        let little = try #require(archived)
        // A window that never had a page leaves nothing.
        let none = state.archiveLittleKite(url: nil, title: "", reason: .manual, now: now)
        #expect(none == nil)
        func ids(_ filter: ArchiveFilter) -> [UUID] {
            state.archiveSections(filter, now: now, calendar: utc).flatMap { $0.items.map(\.tab.id) }
        }
        #expect(ids(ArchiveFilter(source: .littleKite)) == [little])
        // Not a sidebar tab, so no space's filter lists it, even the space that was current.
        #expect(ids(ArchiveFilter(source: .space(state.spaces[1].id))).isEmpty)
        #expect(ids(ArchiveFilter(source: .space(state.spaces[0].id))) == [home])
        #expect(ids(ArchiveFilter(source: .littleKite, reason: .auto)) == [little])
        #expect(ids(ArchiveFilter(source: .littleKite, reason: .manual)).isEmpty)
        #expect(state.archived.last?.isLittleKite == true && state.archived.last?.archivedAt == now)

        // It survives a save.
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.archived.last?.isLittleKite == true)

        // Restore puts it at the top of the current space's Today.
        state.selectSpace(state.spaces[0].id)
        #expect(state.restoreArchived(little, now: now) == state.spaces[0].id)
        #expect(state.spaces[0].tabs.first?.id == little)
        #expect(state.spaces[0].tabs.first?.url == URL(string: "https://news.example/a"))
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

@Suite struct LibraryPageTests {
    @Test func pagesFollowArcsOrderAndNames() {
        #expect(LibraryPage.allCases == [.downloads, .archive, .media, .boosts])
        #expect(LibraryPage.allCases.map(\.rawValue) == ["DownloadsPage", "ArchivePage", "MediaPage", "BoostsPage"])
        #expect(LibraryPage.allCases.map(\.title) == ["Downloads", "Archive", "Media", "Boosts"])
    }

    @Test func remembersTheLastPage() {
        #expect(LibraryPage(stored: "ArchivePage") == .archive)
        #expect(LibraryPage(stored: nil) == .downloads)
        #expect(LibraryPage(stored: "BoostsPage") == .boosts)
        // Pages Arc has and Kite doesn't yet.
        #expect(LibraryPage(stored: "EaselsAndNotesPage") == .downloads)
        #expect(LibraryPage(stored: "SpacesPage") == .downloads)
    }

    @Test func boostsListBySiteThenOldestFirst() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        let library = BoostLibrary(boosts: [
            Boost(name: "Newer", domain: "b.com", createdAt: late),
            Boost(name: "Z", domain: "a.com", createdAt: late),
            Boost(name: "Older", domain: "b.com", createdAt: early),
        ])
        #expect(library.libraryOrder.map(\.name) == ["Z", "Older", "Newer"])
    }
}
