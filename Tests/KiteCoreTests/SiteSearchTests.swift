import Foundation
import Testing
@testable import KiteCore

@Suite struct SiteSearchTests {
    let youtube = SiteSearch(name: "YouTube", shortcut: "yt", urlTemplate: "https://www.youtube.com/results?search_query=%s")
    let amazon = SiteSearch(name: "Amazon", shortcut: "a", urlTemplate: "https://www.amazon.com/s?k=%s")

    @Test func buildsTheSearchURL() {
        #expect(youtube.url(for: "lofi beats & chill")?.absoluteString
            == "https://www.youtube.com/results?search_query=lofi%20beats%20%26%20chill")
    }

    @Test func matchesShortcutsThenPrefixes() {
        let sites = [youtube, amazon]
        #expect(SiteSearch.match("yt", in: sites) == youtube)
        #expect(SiteSearch.match("A", in: sites) == amazon)
        #expect(SiteSearch.match("you", in: sites) == youtube)
        #expect(SiteSearch.match("am", in: sites) == amazon)
        // One letter only matches an exact shortcut; spaces mean a search, not a shortcut.
        #expect(SiteSearch.match("y", in: sites) == nil)
        #expect(SiteSearch.match("yt cats", in: sites) == nil)
        #expect(SiteSearch.match("", in: sites) == nil)
    }

    @Test func convertsChromiumEngines() {
        let site = SiteSearch(chromiumName: "GitHub", keyword: "gh", url: "https://github.com/search?q={searchTerms}")
        #expect(site?.urlTemplate == "https://github.com/search?q=%s")
        #expect(SiteSearch(chromiumName: "Google", keyword: "g", url: "{google:baseURL}search?q={searchTerms}") == nil)
        #expect(SiteSearch(chromiumName: "No query", keyword: "x", url: "https://example.com/") == nil)
        #expect(SiteSearch(chromiumName: "JS", keyword: "js", url: "javascript:alert('{searchTerms}')") == nil)
    }

    @Test func importReplacesSameShortcut() {
        var state = BrowserState.makeDefault()
        state.siteSearches = [youtube]
        let id = youtube.id
        state.mergeSiteSearches([
            SiteSearch(name: "YouTube Music", shortcut: "YT", urlTemplate: "https://music.youtube.com/search?q=%s"),
            amazon,
        ])
        #expect(state.siteSearches.count == 2)
        #expect(state.siteSearches[0].id == id)
        #expect(state.siteSearches[0].name == "YouTube Music")
    }

    @Test func newProfilesHaveArcsDefaults() {
        let state = BrowserState.makeDefault()
        #expect(state.siteSearches.count == SiteSearch.arcDefaults.count)
        #expect(SiteSearch.match("youtube", in: state.siteSearches)?.name == "YouTube")
        #expect(SiteSearch.match("you", in: state.siteSearches)?.shortcut == "youtube.com")
        #expect(SiteSearch.match("wiki", in: state.siteSearches)?.name == "Wikipedia")
    }

    @Test func sessionsFromBeforeDefaultsGetThemOnce() throws {
        var state = BrowserState.makeDefault()
        let mine = SiteSearch(name: "My YouTube", shortcut: "youtube.com", urlTemplate: "https://www.youtube.com/results?q=%s")
        state.siteSearches = [mine]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json["siteSearchDefaultsSeeded"] = nil
        var old = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: json))
        // The user's own youtube.com entry stays; the other defaults are added.
        #expect(old.siteSearches.count == SiteSearch.arcDefaults.count)
        #expect(old.siteSearches.first { $0.shortcut == "youtube.com" }?.name == "My YouTube")

        // A default the user deleted stays deleted after a relaunch.
        old.siteSearches.removeAll { $0.shortcut == "github.com" }
        let relaunched = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(old))
        #expect(!relaunched.siteSearches.contains { $0.shortcut == "github.com" })
    }

    @Test func defaultsSeededWithoutColoursGetThem() throws {
        var state = BrowserState.makeDefault()
        #expect(state.siteSearches.first { $0.shortcut == "youtube.com" }?.color == "FF0000")
        // A version 1 session: defaults without colours, one of them changed by the user.
        for i in state.siteSearches.indices { state.siteSearches[i].color = nil }
        let reddit = try #require(state.siteSearches.firstIndex { $0.shortcut == "reddit.com" })
        state.siteSearches[reddit].name = "My Reddit"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json["siteSearchDefaultsSeeded"] = 1
        let old = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.siteSearches.count == SiteSearch.arcDefaults.count)
        #expect(old.siteSearches.first { $0.shortcut == "youtube.com" }?.color == "FF0000")
        #expect(old.siteSearches.first { $0.shortcut == "reddit.com" }?.color == nil)
    }

    @Test func oldSessionsDecodeWithNoSiteSearches() throws {
        var state = BrowserState.makeDefault()
        state.siteSearches = [youtube]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json["siteSearches"] = nil
        let old = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.siteSearches.isEmpty)
    }
}

@Suite struct SiteSearchEditingTests {
    let youtube = SiteSearch(name: "YouTube", shortcut: "yt", urlTemplate: "https://www.youtube.com/results?search_query=%s", color: "FF0000")

    @Test func validatesTheDialogFields() {
        let sites = [youtube]
        #expect(SiteSearchDraft(name: "Kagi", shortcut: "k", urlTemplate: "https://kagi.com/search?q=%s").isValid(in: sites))
        #expect(SiteSearchDraft().problems(in: sites) == [.emptyName, .emptyShortcut, .invalidURL])
        #expect(SiteSearchDraft(name: "x", shortcut: "a b", urlTemplate: "https://x.com/?q=%s").problems(in: sites) == [.shortcutHasSpace])
        #expect(SiteSearchDraft(name: "x", shortcut: "YT", urlTemplate: "https://x.com/?q=%s").problems(in: sites) == [.shortcutTaken("YouTube")])
        // The entry being edited keeps its own shortcut.
        #expect(SiteSearchDraft(youtube).isValid(in: sites, editing: youtube.id))
        #expect(SiteSearchDraft(name: "x", shortcut: "x", urlTemplate: "https://x.com/").problems(in: sites) == [.invalidURL])
        #expect(SiteSearchDraft(name: "x", shortcut: "x", urlTemplate: "javascript:%s").problems(in: sites) == [.invalidURL])
        #expect(SiteSearchDraft(name: "x", shortcut: "x", urlTemplate: "x.com/?q=%s").problems(in: sites) == [.invalidURL])
    }

    @Test func addsEditsAndRemoves() throws {
        var state = BrowserState.makeDefault()
        state.siteSearches = [youtube]
        let duplicate = state.addSiteSearch(SiteSearchDraft(name: "Dup", shortcut: "yt", urlTemplate: "https://x.com/?q=%s"))
        #expect(duplicate == nil)
        let added = state.addSiteSearch(SiteSearchDraft(name: " Kagi ", shortcut: "k", urlTemplate: "https://kagi.com/search?q=%s"))
        let id = try #require(added)
        #expect(state.siteSearches.last?.name == "Kagi")
        #expect(state.siteSearches.last?.url(for: "a b")?.absoluteString == "https://kagi.com/search?q=a%20b")

        // Renaming keeps the brand colour; a new URL drops it.
        var saved = state.updateSiteSearch(youtube.id, SiteSearchDraft(name: "YT", shortcut: "yt", urlTemplate: youtube.urlTemplate))
        #expect(saved)
        #expect(state.siteSearches[0].color == "FF0000")
        saved = state.updateSiteSearch(youtube.id, SiteSearchDraft(name: "YT", shortcut: "yt", urlTemplate: "https://m.youtube.com/results?q=%s"))
        #expect(saved)
        #expect(state.siteSearches[0].color == nil)
        saved = state.updateSiteSearch(youtube.id, SiteSearchDraft(name: "YT", shortcut: "k", urlTemplate: "https://m.youtube.com/results?q=%s"))
        #expect(!saved)

        state.removeSiteSearch(id)
        #expect(state.siteSearches.map(\.shortcut) == ["yt"])
    }

    @Test func searchEnginesPageURL() {
        #expect(InternalPage(URL(string: "kite://search-engines")) == .searchEngines)
        #expect(InternalPage.searchEngines.url.absoluteString == "kite://search-engines")
    }
}
