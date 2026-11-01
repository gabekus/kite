import Foundation
import Testing
@testable import KiteCore

@Suite struct BrowsingDataTests {
    @Test func settingsPagesRoundTripTheirURLs() {
        let pages: [SettingsPage] = [.privacy, .clearBrowserData, .siteSettings] + SitePermission.allCases.map { .permission($0) }
        for page in pages {
            #expect(SettingsPage(page.url) == page)
            #expect(InternalPage(page.url) == .settings)
        }
        #expect(SettingsPage.permission(.notifications).url.absoluteString == "kite://settings/content/notifications")
        #expect(SettingsPage.clearBrowserData.url.absoluteString == "kite://settings/clearBrowserData")
        #expect(SettingsPage(URL(string: "kite://settings/content/popups")) == nil)
        #expect(SettingsPage(URL(string: "kite://history")) == nil)
        #expect(SettingsPage.clearBrowserData.tabTitle == "Settings - Privacy and security")
    }

    @Test func chipsShowTheFirstThreeAndTheSelectedOne() {
        let (shown, more) = BrowsingDataPeriod.chips(selected: .lastHour)
        #expect(shown == [.lastFifteenMinutes, .lastHour, .lastDay, .lastWeek])
        #expect(more == [.fourWeeks, .allTime])
        let allTime = BrowsingDataPeriod.chips(selected: .allTime)
        #expect(allTime.shown == [.lastFifteenMinutes, .lastHour, .lastDay, .allTime])
        #expect(allTime.more == [.lastWeek, .fourWeeks])
    }

    @Test func periodsReachBackTheirLength() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(BrowsingDataPeriod.lastHour.since(now) == now.addingTimeInterval(-3600))
        #expect(BrowsingDataPeriod.fourWeeks.since(now) == now.addingTimeInterval(-28 * 86400))
        #expect(BrowsingDataPeriod.allTime.since(now) == nil)
        #expect(BrowsingDataPeriod.lastFifteenMinutes.title() == "Last 15 min")
        #expect(BrowsingDataPeriod.lastFifteenMinutes.deletedMessage == "Last 15 minutes deleted")
        #expect(BrowsingDataPeriod.allTime.deletedMessage == "Deleted")
    }

    @Test func checkedTypesJoinTheDefaultThreeBeforeShowMore() {
        let all = BrowsingDataType.allCases
        let plain = BrowsingDataType.split(all, checked: [.history])
        #expect(plain.shown == [.history, .siteData, .cache])
        #expect(plain.more == [.downloads, .formData, .siteSettings, .hostedAppData])
        let withForms = BrowsingDataType.split(all, checked: [.formData])
        #expect(withForms.shown == [.history, .siteData, .cache, .formData])
    }

    @Test func historyLosesOnlyPagesVisitedInTheRange() {
        var history = History()
        let now = Date()
        history.recordVisit(URL(string: "https://old.example")!, title: "Old", at: now.addingTimeInterval(-7200))
        history.recordVisit(URL(string: "https://new.example")!, title: "New", at: now.addingTimeInterval(-60))
        history.removeVisits(since: now.addingTimeInterval(-3600))
        #expect(history.entries.keys.sorted() == ["https://old.example"])
        history.removeVisits(since: nil)
        #expect(history.entries.isEmpty)
    }

    @Test func downloadHistoryKeepsRunningDownloads() {
        let now = Date()
        var list = DownloadList(items: [
            DownloadItem(engineID: 1, url: "https://a/x", path: "/tmp/x", state: .complete, receivedBytes: 1, totalBytes: 1, startedAt: now),
            DownloadItem(engineID: 2, url: "https://a/y", path: "/tmp/y", state: .inProgress, receivedBytes: 0, totalBytes: 1, startedAt: now),
            DownloadItem(engineID: 3, url: "https://a/z", path: "/tmp/z", state: .complete, receivedBytes: 1, totalBytes: 1,
                         startedAt: now.addingTimeInterval(-86400)),
        ])
        list.removeHistory(since: now.addingTimeInterval(-3600))
        #expect(list.items.map(\.engineID) == [2, 3])
    }

    @Test func exceptionsReadChromiumsPref() {
        let recent = String(Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000))
        let pref: [String: Any] = [
            "https://b.example:443,*": ["setting": NSNumber(value: 2), "last_modified": "13300000000000000"],
            "https://a.example:443,*": ["setting": NSNumber(value: 1), "last_modified": recent],
            "http://c.example:8080,*": ["setting": NSNumber(value: 1)],
            "https://d.example:443,*": ["setting": NSNumber(value: 3)],
        ]
        let list = PermissionException.list(pref)
        #expect(list.map(\.site) == ["http://c.example:8080", "https://a.example", "https://b.example"])
        #expect(list.map(\.value) == [.allow, .allow, .block])
        let kept = PermissionException.removing(from: pref, since: Date().addingTimeInterval(-3600))
        #expect(Set(kept.keys) == ["https://b.example:443,*", "http://c.example:8080,*", "https://d.example:443,*"])
        #expect(PermissionException.removing(from: pref, since: nil).isEmpty)
    }
}
