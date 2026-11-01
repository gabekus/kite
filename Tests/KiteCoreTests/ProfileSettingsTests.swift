import Foundation
import Testing
@testable import KiteCore

@Suite struct ProfileSettingsTests {
    @Test func defaultsMatchArc() {
        let state = BrowserState.makeDefault(seedURL: nil)
        let settings = state.settings(ofProfile: Profile.defaultDirectory)
        #expect(settings.downloadDirectory == nil)
        #expect(!settings.promptsForDownload)
        #expect(settings.includesSearchSuggestions)
    }

    @Test func eachProfileKeepsItsOwn() throws {
        var state = BrowserState.makeDefault(seedURL: nil)
        let work = try state.createProfile(named: "Work")
        state.updateSettings(ofProfile: work.directory) {
            $0.downloadDirectory = "/tmp/work"
            $0.includesSearchSuggestions = false
        }
        state.updateSettings(ofProfile: nil) { $0.promptsForDownload = true }

        #expect(state.settings(ofProfile: work.directory).downloadDirectory == "/tmp/work")
        #expect(!state.settings(ofProfile: work.directory).includesSearchSuggestions)
        #expect(!state.settings(ofProfile: work.directory).promptsForDownload)
        // nil (incognito) is the default profile's.
        #expect(state.settings(ofProfile: Profile.defaultDirectory).promptsForDownload)
        #expect(state.settings(ofProfile: Profile.defaultDirectory).includesSearchSuggestions)
    }

    @Test func survivesSaveAndLoad() throws {
        var state = BrowserState.makeDefault(seedURL: nil)
        state.updateSettings(ofProfile: nil) { $0.downloadDirectory = "/tmp/a"; $0.includesSearchSuggestions = false }
        let data = try JSONEncoder().encode(state)
        let loaded = try JSONDecoder().decode(BrowserState.self, from: data)
        #expect(loaded.settings(ofProfile: nil) == state.settings(ofProfile: nil))
        // Back to the defaults leaves nothing stored.
        state.updateSettings(ofProfile: nil) { $0 = ProfileSettings() }
        #expect(state.profileSettings.isEmpty)
    }

    @Test func missingFolderFallsBackToDownloads() {
        let downloads = URL(fileURLWithPath: "/Users/x/Downloads")
        var settings = ProfileSettings()
        #expect(settings.downloadFolder(downloads: downloads, exists: { _ in true }) == downloads)
        settings.downloadDirectory = "/Volumes/Gone"
        #expect(settings.downloadFolder(downloads: downloads, exists: { _ in false }) == downloads)
        #expect(settings.downloadFolder(downloads: downloads, exists: { _ in true }).path == "/Volumes/Gone")
    }
}

@Suite struct SearchSuggestionsTests {
    @Test func gate() {
        let on = ProfileSettings()
        let off = ProfileSettings(includesSearchSuggestions: false)
        #expect(SearchSuggestions.shouldFetch("kite", settings: on, inSiteSearch: false))
        #expect(!SearchSuggestions.shouldFetch("kite", settings: off, inSiteSearch: false))
        #expect(!SearchSuggestions.shouldFetch("kite", settings: on, inSiteSearch: true))
        #expect(!SearchSuggestions.shouldFetch("  ", settings: on, inSiteSearch: false))
        #expect(!SearchSuggestions.shouldFetch("example.com", settings: on, inSiteSearch: false))
    }

    @Test func requestURLs() {
        #expect(SearchSuggestions.requestURL(for: "a b", engine: .google)?.absoluteString
            == "https://www.google.com/complete/search?client=chrome&q=a%20b")
        #expect(SearchSuggestions.requestURL(for: "x", engine: .duckDuckGo)?.absoluteString
            == "https://duckduckgo.com/ac/?q=x&type=list")
        #expect(SearchSuggestions.requestURL(for: "x", engine: .kagi) == nil)
        #expect(SearchSuggestions.requestURL(for: "c&d", engine: .kagi, template: "http://127.0.0.1:9/s?q={searchTerms}")?.absoluteString
            == "http://127.0.0.1:9/s?q=c%26d")
    }

    @Test func parsesOpenSearchAnswers() {
        let google = Data(#"["kite",["kite","Kite Runner","kite surfing","kite runner","kites","kite festival"],["","","",""],[],{}]"#.utf8)
        #expect(SearchSuggestions.parse(google, query: "Kite ") == ["Kite Runner", "kite surfing", "kites", "kite festival"])
        let guarded = Data(")]}'\n[\"a\",[\"ab\"]]".utf8)
        #expect(SearchSuggestions.parse(guarded, query: "a") == ["ab"])
        #expect(SearchSuggestions.parse(Data("not json".utf8), query: "a").isEmpty)
        #expect(SearchSuggestions.parse(Data(#"{"a":1}"#.utf8), query: "a").isEmpty)
    }
}
