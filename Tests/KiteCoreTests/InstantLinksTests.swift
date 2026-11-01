import Foundation
import Testing
@testable import KiteCore

@Suite struct InstantLinksTests {
    @Test func readsThePlan() {
        let reply = """
            ```json
            {"title": "Greek and Italian Restaurants", "queries": ["greek restaurants greenpoint", "italian restaurants greenpoint"], "format": "split",}
            ```
            """
        let plan = InstantLinks.plan(from: reply, input: "greek and italian restaurants greenpoint in a split")
        #expect(plan == InstantLinks.Plan(title: "Greek and Italian Restaurants",
                                          queries: ["greek restaurants greenpoint", "italian restaurants greenpoint"],
                                          format: .split))
    }

    @Test func defaultsAndRejects() {
        // No format or title: a tab, titled with the input.
        #expect(InstantLinks.plan(from: #"{"queries":["dune trailer"]}"#, input: " dune trailer ")
            == InstantLinks.Plan(title: "dune trailer", queries: ["dune trailer"], format: .tab))
        #expect(InstantLinks.plan(from: #"{"queries":["x"],"format":"grid"}"#, input: "x")?.format == .tab)
        #expect(InstantLinks.plan(from: "Sorry, I can't help.", input: "x") == nil)
        #expect(InstantLinks.plan(from: #"{"title":"t","queries":["  "]}"#, input: "x") == nil)
        let many = (1...10).map { "\"q\($0)\"" }.joined(separator: ",")
        #expect(InstantLinks.plan(from: "{\"queries\":[\(many)]}", input: "x")?.queries.count == InstantLinks.maxQueries)
    }

    @Test func picksTheFirstRealResult() {
        let links = [
            "https://www.google.com/search?q=dune&tbm=isch",
            "https://maps.google.com/?q=dune",
            "javascript:void(0)",
            "https://www.google.com/url?q=https://www.youtube.com/watch%3Fv%3DU2Qp5pL3ovA&sa=U",
            "https://www.imdb.com/title/tt15239678/",
        ]
        #expect(InstantLinks.topResult(fromLinks: links)?.absoluteString == "https://www.youtube.com/watch?v=U2Qp5pL3ovA")
        #expect(InstantLinks.topResult(fromLinks: ["https://webcache.googleusercontent.com/x", "https://blog.google.org.example.com/"])?.host()
            == "blog.google.org.example.com")
        #expect(InstantLinks.topResult(fromLinks: ["https://www.google.co.uk/preferences"]) == nil)
        // Google's opaque redirects are returned for the caller to follow.
        let goto = InstantLinks.topResult(fromLinks: ["https://www.google.com/search?q=x", "https://www.google.com/goto?url=CAESZgHr"])
        #expect(goto.map(InstantLinks.isGoogleRedirect) == true)
        #expect(!InstantLinks.isGoogleRedirect(URL(string: "https://www.youtube.com/goto")!))
        #expect(InstantLinks.topResult(fromLinks: ["https://googleblog.com/post"])?.host() == "googleblog.com")
    }

    @Test func onlyForSearches() {
        #expect(InstantLinks.applies(to: "dune trailer"))
        #expect(!InstantLinks.applies(to: "  "))
        #expect(!InstantLinks.applies(to: "github.com"))
        #expect(InstantLinks.googleURL(for: "a & b")?.absoluteString == "https://www.google.com/search?q=a%20%26%20b")
    }
}

@Suite struct InstantLinksOpeningTests {
    let urls = (1...5).map { URL(string: "https://example.com/\($0)")! }

    @Test func opensTabsInQueryOrder() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let ids = state.openInstantLinks(Array(urls.prefix(3)), title: "t", format: .tab)
        #expect(state.selectedTab?.id == ids[0])
        #expect(Array(state.selectedSpace.tabs.prefix(3).map(\.url)) == Array(urls.prefix(3)))
    }

    @Test func opensASplitOfAtMostFourPanes() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let ids = state.openInstantLinks(urls, title: "t", format: .split)
        #expect(state.selectedSplit?.tabIDs == Array(ids.prefix(4)))
        #expect(state.selectedTab?.id == ids[0])
    }

    @Test func opensAFolderNamedAfterThePlan() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let ids = state.openInstantLinks(Array(urls.prefix(2)), title: "Ramen Recipes", format: .folder)
        let folder = state.folders(inSpace: state.selectedSpaceIndex).first { $0.name == "Ramen Recipes" }
        #expect(folder != nil)
        #expect(ids.allSatisfy { id in state.selectedSpace.tabs.allSatisfy { $0.id != id } })
        #expect(state.selectedTab?.id == ids[0])
    }
}
