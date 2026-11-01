import Foundation
import Testing
@testable import KiteCore

/// Hand-made fixtures shaped like Arc's StorableArchiveItems.json and its defaults.
@Suite struct ArcArchiveSettingsImportTests {
    private static func id(_ n: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", n)
    }

    private static func archived(_ n: Int, at: Double, source: [String: Any], title: String? = nil) -> [String: Any] {
        [
            "archivedAt": at,
            "reason": "manual",
            "source": source,
            "sidebarItem": [
                "id": id(n), "title": title as Any, "childrenIds": [], "parentID": NSNull(),
                "data": ["tab": ["savedURL": "https://archived\(n).example/", "savedTitle": "Archived \(n)", "timeLastActiveAt": at - 60]],
            ],
        ]
    }

    static let archiveFixture: Data = {
        let entries = [
            archived(2, at: 800_000_200, source: ["littleArc": [:]]),
            archived(1, at: 800_000_100, source: ["space": ["_0": id(9)]], title: "Renamed"),
            archived(3, at: 800_000_300, source: ["unknown": [:]]),
        ]
        var items: [Any] = []
        for entry in entries { items += [(entry["sidebarItem"] as! [String: Any])["id"]!, entry] }
        items += [id(4), ["archivedAt": 1.0, "sidebarItem": ["id": id(4), "data": ["list": [:]]]]]
        return try! JSONSerialization.data(withJSONObject: ["version": 1, "items": items])
    }()

    @Test func importsArchivedTabsOldestFirst() {
        let tabs = ArcArchiveImport.parse(Self.archiveFixture)
        #expect(tabs.map(\.tab.title) == ["Renamed", "Archived 2", "Archived 3"])
        #expect(tabs[0].tab.id == UUID(uuidString: Self.id(1)))
        #expect(tabs[0].spaceID == UUID(uuidString: Self.id(9)))
        #expect(tabs[1].spaceID == ArcArchiveImport.noSpace)
        #expect(tabs[0].tab.lastActiveAt == Date(timeIntervalSinceReferenceDate: 800_000_040))
        #expect(ArcArchiveImport.parse(Data("{}".utf8)).isEmpty)
    }

    @Test func archiveMergeGoesBeforeKitesOwnAndSkipsRepeats() {
        var state = BrowserState.makeDefault(seedURL: nil)
        let own = ClosedTab(tab: BrowserTab(url: URL(string: "https://own.example/")), spaceID: state.selectedSpaceID, index: 0)
        state.archived = [own]
        let imported = ArcArchiveImport.parse(Self.archiveFixture)
        #expect(state.mergeArchive(imported: imported) == 3)
        #expect(state.mergeArchive(imported: imported) == 0)
        #expect(state.archived.map(\.tab.id) == imported.map(\.tab.id) + [own.tab.id])
    }

    @Test func archiveMergeKeepsTheNewestWithinTheLimit() {
        var state = BrowserState.makeDefault(seedURL: nil)
        let many = (0..<(BrowserState.archiveLimit + 10)).map { _ in
            ClosedTab(tab: BrowserTab(url: URL(string: "https://a.example/")), spaceID: ArcArchiveImport.noSpace, index: 0)
        }
        #expect(state.mergeArchive(imported: many) == BrowserState.archiveLimit)
        #expect(state.archived.first?.tab.id == many[10].tab.id)
        #expect(state.archived.last?.tab.id == many.last?.tab.id)
    }

    @Test func readsArcSettings() {
        let defaults: [String: Any] = [
            "shouldWarnBeforeQuitting": false,
            "openExternalLinksInLittleBrowserEnabled": true,
            "autoArchiveTimeThresholdsPerProfile": #"{"thresholds":[{"custom":{"_0":{"directoryBasename":"Profile 1"}}},"oneHour",{"default":{}},{"sevenDays":{}}]}"#,
        ]
        let settings = ArcSettings(defaults: defaults)
        #expect(settings == ArcSettings(warnsBeforeQuitting: false, opensExternalLinksInLittleKite: true, archiveAfter: .sevenDays))
        #expect(settings.names.count == 3)

        var state = BrowserState.makeDefault(seedURL: nil)
        state.apply(settings)
        #expect(state.warnsBeforeQuitting == false)
        #expect(state.archiveAfter == .sevenDays)
    }

    @Test func arcDefaultsLeaveKiteAlone() {
        // Arc's untouched defaults: no thresholds, no other keys.
        let settings = ArcSettings(defaults: ["autoArchiveTimeThresholdsPerProfile": #"{"thresholds":[]}"#])
        #expect(settings.isEmpty)
        // With only another profile's threshold, Kite's single profile takes it.
        #expect(ArcSettings.archiveInterval(#"{"thresholds":[{"custom":{}},"thirtyDays"]}"#) == .thirtyDays)
        #expect(ArcSettings.archiveInterval("not json") == nil)
        #expect(ArcSettings(defaults: ["shouldWarnBeforeQuitting": "yes"]).warnsBeforeQuitting == nil)
    }

    @Test func historyMergeKeepsLaterVisitsAndDoesNotDoubleCount() {
        var history = History()
        let page = URL(string: "https://page.example/")!
        history.recordVisit(page, title: "Kite title", at: Date(timeIntervalSince1970: 2_000))
        let imported = [
            HistoryEntry(url: page, title: "Arc title", lastVisit: Date(timeIntervalSince1970: 1_000), visitCount: 5),
            HistoryEntry(url: URL(string: "https://new.example/")!, title: "New", lastVisit: Date(timeIntervalSince1970: 500), visitCount: 2),
            HistoryEntry(url: URL(string: "file:///tmp/x")!, title: "Local", lastVisit: Date(timeIntervalSince1970: 500)),
        ]
        #expect(history.merge(imported) == 1)
        #expect(history.merge(imported) == 0)
        let entry = history.entries[page.absoluteString]
        #expect(entry?.title == "Kite title")
        #expect(entry?.visitCount == 5)
        #expect(entry?.lastVisit == Date(timeIntervalSince1970: 2_000))
        #expect(history.entries.count == 2)
    }

    @Test func chromiumTimestamps() {
        // 2001-01-01 00:00:00 UTC in Chromium's microseconds since 1601.
        #expect(History.chromiumDate(12_622_780_800_000_000) == Date(timeIntervalSinceReferenceDate: 0))
    }
}
