import Foundation
import Testing
@testable import KiteCore

@Suite struct LittleKiteTests {
    @Test func webLinksOpenInLittleKiteWhileTheSettingIsOn() {
        let url = URL(string: "https://example.com/a")!
        #expect(LittleKite.destination(for: url, opensExternalLinks: true) == .littleKite)
        #expect(LittleKite.destination(for: URL(string: "HTTP://example.com")!, opensExternalLinks: true) == .littleKite)
        #expect(LittleKite.destination(for: url, opensExternalLinks: false) == .tab)
    }

    @Test func filesAndOtherSchemesStillOpenAsTabs() {
        #expect(LittleKite.destination(for: URL(fileURLWithPath: "/tmp/page.html"), opensExternalLinks: true) == .tab)
        #expect(LittleKite.destination(for: URL(string: "mailto:a@b.c")!, opensExternalLinks: true) == .tab)
    }

    @Test func settingDefaultsToOnAndFollowsTheStoredValue() throws {
        let suite = "LittleKiteTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LittleKite.opensExternalLinksByDefault)
        #expect(LittleKite.opensExternalLinks(in: defaults))
        defaults.set(false, forKey: LittleKite.opensExternalLinksKey)
        #expect(!LittleKite.opensExternalLinks(in: defaults))
        defaults.set(true, forKey: LittleKite.opensExternalLinksKey)
        #expect(LittleKite.opensExternalLinks(in: defaults))
    }

    @Test func windowTitleNamesThePage() {
        #expect(LittleKite.windowTitle(pageTitle: nil) == "Little Kite")
        #expect(LittleKite.windowTitle(pageTitle: "  ") == "Little Kite")
        #expect(LittleKite.windowTitle(pageTitle: "Example") == "Little Kite — Example")
    }

    @Test func hostDropsWWW() {
        #expect(LittleKite.displayHost(of: URL(string: "https://www.example.com/x")) == "example.com")
        #expect(LittleKite.displayHost(of: URL(string: "https://news.example.com")) == "news.example.com")
        #expect(LittleKite.displayHost(of: nil) == "")
    }
}

@Suite struct LittleKitePillAndTrayTests {
    @Test func pillButtonsMatchArcsLittleWindow() {
        // Arc's 1784pt window: pill from 107 to 1588.5 (1481.5 wide), extensions at 1530.5, copy at 1565.
        let buttons = LittleKite.pillButtons(pillWidth: 1481.5, showsExtensions: true)
        #expect(buttons.copyX + 107 == 1565)
        #expect(buttons.extensionsX.map { $0 + 107 } == 1530.5)
        #expect(buttons.labelTrailing == buttons.extensionsX! - LittleKite.Pill.labelGap)
    }

    @Test func withoutExtensionsTheTextRunsUpToCopyLink() {
        let buttons = LittleKite.pillButtons(pillWidth: 400, showsExtensions: false)
        #expect(buttons.extensionsX == nil)
        #expect(buttons.copyX == 400 - 7.5 - 16)
        #expect(buttons.labelTrailing == buttons.copyX - 8)
    }

    @Test func trayKeepsOneCardPerDownloadInOrder() {
        var tray = LittleKite.DownloadsTray()
        #expect(tray.isEmpty)
        let a = UUID(), b = UUID(), c = UUID()
        tray.add(a)
        tray.add(b)
        tray.add(a)
        tray.add(c)
        #expect(tray.ids == [a, b, c])
        tray.dismiss(b)
        #expect(tray.ids == [a, c])
        tray.keep(only: [c])
        #expect(tray.ids == [c])
        tray.dismiss(c)
        #expect(tray.isEmpty)
    }

    @Test func trayGeometryIsArcs() {
        typealias Tray = LittleKite.DownloadsTray
        #expect(Tray.height == Tray.inset * 2 + Tray.itemHeight)
        #expect(Tray.itemX(at: 0) == 20)
        #expect(Tray.itemX(at: 2) == 540.0)
        #expect(Tray.contentWidth(count: 0) == 0)
        #expect(Tray.contentWidth(count: 1) == 290)
        // 20 in, three 250pt cards 10pt apart, 20 out.
        #expect(Tray.contentWidth(count: 3) == 810.0)
    }
}

@Suite struct LittleKiteLinksSettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "LittleKiteLinks-\(UUID().uuidString)"))
    }

    @Test func switchesDefaultToOnAsArcs() throws {
        let defaults = try makeDefaults()
        #expect(LittleKite.globalHotkeyEnabled(in: defaults))
        #expect(LittleKite.opensOnOptionCommandClick(in: defaults))
        defaults.set(false, forKey: LittleKite.globalHotkeyKey)
        defaults.set(false, forKey: LittleKite.optionCommandClickKey)
        #expect(!LittleKite.globalHotkeyEnabled(in: defaults))
        #expect(!LittleKite.opensOnOptionCommandClick(in: defaults))
    }

    @Test func archiveThresholdIsArcsThreeChoicesWithSixHoursByDefault() throws {
        #expect(LittleKite.ArchiveThreshold.allCases.map(\.title) == ["1 hour", "6 hours (default)", "12 hours"])
        let defaults = try makeDefaults()
        #expect(LittleKite.ArchiveThreshold.current(in: defaults) == .sixHours)
        defaults.set("oneHour", forKey: LittleKite.ArchiveThreshold.key)
        #expect(LittleKite.ArchiveThreshold.current(in: defaults) == .oneHour)
        defaults.set("bogus", forKey: LittleKite.ArchiveThreshold.key)
        #expect(LittleKite.ArchiveThreshold.current(in: defaults) == .sixHours)
    }

    @Test func aWindowGoesOnlyOnceUnusedPastTheThreshold() {
        let now = Date()
        let t = LittleKite.ArchiveThreshold.oneHour
        #expect(!t.isStale(lastActive: now.addingTimeInterval(-3599), inUse: false, now: now))
        #expect(t.isStale(lastActive: now.addingTimeInterval(-3600), inUse: false, now: now))
        #expect(!t.isStale(lastActive: now.addingTimeInterval(-90000), inUse: true, now: now))
    }

    @Test func hotkeyCodesMatchCarbon() {
        #expect(LittleKite.virtualKeyCode(for: "n") == 0x2D)
        #expect(LittleKite.virtualKeyCode(for: "N") == 0x2D)
        #expect(LittleKite.virtualKeyCode(for: "left") == 0x7B)
        #expect(LittleKite.virtualKeyCode(for: "§") == nil)
        // cmdKey | optionKey
        #expect(LittleKite.carbonModifiers([.option, .command]) == 0x0900)
    }
}

@Suite struct LittleKiteMoveMenuTests {
    private let work = LittleKite.MoveMenu.Option(id: UUID(), name: "Work")
    private let home = LittleKite.MoveMenu.Option(id: UUID(), name: "Home")
    private let cafe = LittleKite.MoveMenu.Option(id: UUID(), name: "Café")

    private var menu: LittleKite.MoveMenu { .init(options: [work, home, cafe], primaryID: home.id) }

    @Test func startsWithEverySpaceAndTheFirstHighlighted() {
        #expect(menu.results == [work, home, cafe])
        #expect(menu.highlighted == work)
    }

    @Test func searchIgnoresCaseAndAccentsAndHighlightsTheFirstMatch() {
        var m = menu
        m.updateQuery("CAFE")
        #expect(m.results == [cafe])
        #expect(m.highlighted == cafe)
        m.updateQuery("o")
        #expect(m.results == [work, home])
        #expect(m.highlighted == work)
        m.updateQuery("zzz")
        #expect(m.results.isEmpty)
        #expect(m.highlighted == nil)
        m.updateQuery("  ")
        #expect(m.results.count == 3)
    }

    @Test func arrowsMoveTheHighlightAndStopAtTheEnds() {
        var m = menu
        m.selectPrevious()
        #expect(m.highlighted == work)
        m.selectNext()
        m.selectNext()
        #expect(m.highlighted == cafe)
        m.selectNext()
        #expect(m.highlighted == cafe)
        m.hover(home.id)
        #expect(m.highlighted == home)
        m.updateQuery("work")
        m.hover(home.id)
        #expect(m.highlighted == work)
    }

    @Test func heightGrowsWithRowsUpTo350() {
        #expect(LittleKite.MoveMenu.listHeight(count: 0) == 0)
        #expect(LittleKite.MoveMenu.listHeight(count: 3) == 138)
        #expect(LittleKite.MoveMenu.listHeight(count: 20) == 350)
        #expect(menu.height == 46 + 138)
    }

    @Test func indicatorAndChevronNeedMoreThanOne() {
        #expect(!LittleKite.showsProfileIndicator(profileCount: 1))
        #expect(LittleKite.showsProfileIndicator(profileCount: 2))
        #expect(!LittleKite.hasAdditionalDestinations(spaceCount: 1))
        #expect(LittleKite.hasAdditionalDestinations(spaceCount: 2))
    }
}
