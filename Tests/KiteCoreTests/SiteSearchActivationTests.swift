import Foundation
import Testing
@testable import KiteCore

/// The search engines page's Inactive shortcuts and filter field (g123), and the command bar's
/// search suggestions privacy banner (g122).
@Suite struct SiteSearchActivationTests {
    let youtube = SiteSearch(name: "YouTube", shortcut: "yt", urlTemplate: "https://www.youtube.com/results?search_query=%s")

    @Test func deactivatedShortcutsLeaveTheCommandBar() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let id = state.addSiteSearch(SiteSearchDraft(name: "YouTube Kids", shortcut: "ytk", urlTemplate: "https://www.youtubekids.com/search?q=%s"))!
        #expect(state.activeSiteSearches.contains { $0.id == id })
        state.setSiteSearch(id, active: false)
        #expect(!state.activeSiteSearches.contains { $0.id == id })
        #expect(state.siteSearches.contains { $0.id == id })
        #expect(SiteSearch.match("ytk", in: state.activeSiteSearches)?.id != id)
        state.setSiteSearch(id, active: true)
        #expect(SiteSearch.match("ytk", in: state.activeSiteSearches)?.id == id)
    }

    @Test func activeStateSurvivesSavingAndOldSessionsLoadActive() throws {
        var site = youtube
        site.isActive = false
        let data = try JSONEncoder().encode(site)
        #expect(try JSONDecoder().decode(SiteSearch.self, from: data).isActive == false)
        let old = #"{"id":"\#(UUID().uuidString)","name":"YouTube","shortcut":"yt","urlTemplate":"https://y.com/?q=%s"}"#
        #expect(try JSONDecoder().decode(SiteSearch.self, from: Data(old.utf8)).isActive)
    }

    @Test func filterMatchesNameShortcutOrURLIgnoringCase() {
        #expect(youtube.matchesFilter(""))
        #expect(youtube.matchesFilter("tube"))
        #expect(youtube.matchesFilter("YT"))
        #expect(youtube.matchesFilter("search_query"))
        #expect(!youtube.matchesFilter("amazon"))
    }

    @Test func privacyBannerShowsWithEngineSuggestionsUntilDismissed() throws {
        #expect(SearchSuggestions.showsPrivacyBanner(hasEngineSuggestions: true, dismissed: false))
        #expect(!SearchSuggestions.showsPrivacyBanner(hasEngineSuggestions: false, dismissed: false))
        #expect(!SearchSuggestions.showsPrivacyBanner(hasEngineSuggestions: true, dismissed: true))
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        state.hasDismissedSearchSuggestionsPrivacy = true
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.hasDismissedSearchSuggestionsPrivacy)
    }
}
