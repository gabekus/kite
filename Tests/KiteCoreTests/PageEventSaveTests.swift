import Foundation
import Testing
@testable import KiteCore

/// A page setting `document.title` on a timer: what it costs in history and session saves.
@Suite struct PageEventSaveTests {
    private func url(_ path: String) -> URL { URL(string: "https://example.com/\(path)")! }

    @Test func updateTitleReportsWhetherTheEntryChanged() {
        var history = History()
        let page = url("clock")
        let unknown = history.updateTitle(page, "Before the visit")
        #expect(!unknown)
        #expect(history.entries.isEmpty)
        history.recordVisit(page, title: "")
        let first = history.updateTitle(page, "12:00:01")
        let repeated = history.updateTitle(page, "12:00:01")
        let empty = history.updateTitle(page, "")
        #expect(first)
        #expect(!repeated)
        #expect(!empty)
        #expect(history.entries[page.absoluteString]?.title == "12:00:01")
        #expect(history.updatesTitle(page, "12:00:02"))
        #expect(!history.updatesTitle(page, "12:00:01"))
    }

    @Test func historyFileRoundTripsAndStartsEmptyWithoutAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = HistoryFile(fileURL: dir.appendingPathComponent("history.json"))
        #expect(try file.load() == nil)
        var history = History()
        history.recordVisit(url("a"), title: "A", at: Date(timeIntervalSince1970: 1_800_000_000))
        try file.save(history)
        #expect(try file.load() == history)
    }

    @Test func unreadableHistoryFileIsMovedAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = HistoryFile(fileURL: dir.appendingPathComponent("history.json"))
        try Data("not json".utf8).write(to: file.fileURL)
        #expect(throws: (any Error).self) { try file.load() }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left.count == 1)
        #expect(left.first?.hasPrefix("history.corrupt-") == true)
    }

    @Test func pageEventsWaitLongerAndNeverPushBackAWaitingSave() {
        #expect(SessionSaveDelay.pageEvent.seconds > SessionSaveDelay.soon.seconds)
        // Nothing waiting: each arms its own delay.
        #expect(SessionSaveDelay.soon.rearm(pending: nil) == 1)
        #expect(SessionSaveDelay.pageEvent.rearm(pending: nil) == 10)
        // A ticking title leaves the waiting save alone, so it still lands.
        #expect(SessionSaveDelay.pageEvent.rearm(pending: .pageEvent) == nil)
        #expect(SessionSaveDelay.pageEvent.rearm(pending: .soon) == nil)
        // A sidebar change brings a waiting page save forward, and debounces as before.
        #expect(SessionSaveDelay.soon.rearm(pending: .pageEvent) == 1)
        #expect(SessionSaveDelay.soon.rearm(pending: .soon) == 1)
    }

    @Test func pendingSaveWiresTheRearmRules() {
        var save = PendingSave()
        #expect(save.arm(.pageEvent) == 10)
        #expect(save.pending == .pageEvent)
        // Ticks while it waits leave it alone.
        #expect(save.arm(.pageEvent) == nil)
        #expect(save.pending == .pageEvent)
        // A navigation or sidebar change brings it forward; ticks then leave that alone too.
        #expect(save.arm(.soon) == 1)
        #expect(save.pending == .soon)
        #expect(save.arm(.pageEvent) == nil)
        #expect(save.arm(.soon) == 1)
        save.saved()
        #expect(save.pending == nil)
        #expect(save.arm(.pageEvent) == 10)
    }

    @Test func cappedDebounceNeverWaitsPastItsMaximum() {
        var debounce = CappedDebounce(quiet: 3, maxWait: 30)
        #expect(debounce.changed(at: 100) == 3)
        // A title every second: the quiet wait, until the cap closes in.
        #expect(debounce.changed(at: 101) == 3)
        #expect(debounce.changed(at: 128) == 2)
        #expect(debounce.changed(at: 129.5) == 0.5)
        #expect(debounce.changed(at: 131) == 0)
        debounce.saved()
        #expect(debounce.pendingSince == nil)
        #expect(debounce.changed(at: 140) == 3)
        #expect(debounce.pendingSince == 140)
    }

    /// `mutatePage` keeps `syncPinnedURLs`: a pinned tab that had no page yet adopts the first URL it reports.
    @Test func pinnedTabWithoutAPageAdoptsItsFirstURL() {
        var state = BrowserState.makeDefault()
        let id = state.openTab(url: nil)
        state.togglePin(tab: id)
        #expect(state.tab(id)?.pinnedURL == nil)
        state.update(tab: id) { $0.url = self.url("first") }
        state.syncPinnedURLs()
        #expect(state.tab(id)?.pinnedURL == url("first"))
        // Later navigations leave the pinned page alone.
        state.update(tab: id) { $0.url = self.url("second") }
        state.syncPinnedURLs()
        #expect(state.tab(id)?.pinnedURL == url("first"))
    }

    /// BrowserStore's page-event path skips the undo comparison and Tidy Tab Titles: neither may
    /// ever see a title, URL or favicon change, for pinned, Today and favorite tabs alike.
    @Test func pageEventsAreNeverUndoableAndNeverPinATab() {
        var state = BrowserState.makeDefault()
        let today = state.openTab(url: url("today"))
        let pinned = state.openTab(url: url("pinned"))
        state.togglePin(tab: pinned)
        let favorite = state.openTab(url: url("favorite"))
        state.toggleFavorite(tab: favorite)
        for id in [today, pinned, favorite] {
            let before = state
            state.update(tab: id) {
                $0.title = "Tick \(id)"
                $0.url = self.url("next/\(id)")
                $0.faviconURL = self.url("favicon.ico")
            }
            #expect(state.tab(id)?.title == "Tick \(id)")
            #expect(!SidebarUndo.isUndoable(from: before, to: state))
            #expect(TidyTabTitles.newlyPinnedTabs(before: before, after: state).isEmpty)
        }
    }
}
