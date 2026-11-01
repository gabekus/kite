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
