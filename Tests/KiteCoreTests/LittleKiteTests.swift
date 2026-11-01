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
