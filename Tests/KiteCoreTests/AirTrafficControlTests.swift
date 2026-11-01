import Foundation
import Testing
@testable import KiteCore

@Suite struct AirTrafficControlTests {
    typealias ATC = AirTrafficControl
    let work = UUID()
    let personal = UUID()
    var spaces: Set<UUID> { [work, personal] }

    func url(_ s: String) -> URL { URL(string: s)! }

    @Test func containsIsACaseInsensitiveSubstringOfTheLink() {
        let c = ATC.Component(style: .contains, pattern: "Spotify")
        #expect(c.matches(url("https://open.spotify.com/track/1")))
        #expect(c.matches(url("https://example.com/?q=spotify")))
        #expect(!c.matches(url("https://example.com/")))
    }

    @Test func isEqualToMatchesTheSiteOrTheWholeLink() {
        let site = ATC.Component(style: .matches, pattern: "figma.com")
        #expect(site.matches(url("https://www.figma.com/file/abc")))
        #expect(site.matches(url("http://figma.com")))
        #expect(!site.matches(url("https://help.figma.com/")))

        let page = ATC.Component(style: .matches, pattern: "https://example.com/a/")
        #expect(page.matches(url("https://www.example.com/a")))
        #expect(!page.matches(url("https://example.com/a/b")))
    }

    @Test func emptyPatternsNeverMatch() {
        #expect(!ATC.Component(style: .contains, pattern: "  ").matches(url("https://example.com")))
        #expect(!ATC.Component(style: .matches, pattern: "").matches(url("https://example.com")))
    }

    @Test func aRuleMatchesWhenAnyComponentDoes() {
        let rule = ATC.Rule(components: [.init(pattern: "notion.so"), .init(pattern: "linear.app")], destination: .space(work))
        #expect(rule.matches(url("https://linear.app/team")))
        #expect(!rule.matches(url("https://github.com")))
    }

    @Test func theFirstMatchingRuleWinsThenTheDefault() {
        let state = ATC.State(rules: [
            .init(components: [.init(pattern: "spotify")], destination: .space(personal)),
            .init(components: [.init(pattern: "open.spotify")], destination: .littleKite),
            .init(components: [.init(style: .matches, pattern: "github.com")], destination: .space(work)),
        ])
        func dest(_ s: String, little: Bool = true) -> ATC.Destination {
            state.destination(for: url(s), spaceIDs: spaces, opensExternalLinksInLittleKite: little)
        }
        #expect(dest("https://open.spotify.com/x") == .space(personal))
        #expect(dest("https://github.com/gabekus/kite") == .space(work))
        #expect(dest("https://example.com") == .littleKite)
        #expect(dest("https://example.com", little: false) == .mostRecentSpace)
    }

    @Test func aStoredDefaultOverridesTheLittleKiteSetting() {
        let state = ATC.State(defaultDestination: .space(work))
        #expect(state.destination(for: url("https://a.com"), spaceIDs: spaces, opensExternalLinksInLittleKite: true) == .space(work))
        #expect(state.resolvedDefault(opensExternalLinksInLittleKite: false) == .space(work))
    }

    @Test func routesToDeletedSpacesAreSkipped() {
        let gone = UUID()
        let state = ATC.State(
            rules: [.init(components: [.init(pattern: "a.com")], destination: .space(gone))],
            defaultDestination: .space(gone)
        )
        #expect(state.destination(for: url("https://a.com"), spaceIDs: spaces, opensExternalLinksInLittleKite: true) == .mostRecentSpace)
    }

    @Test func filesAndOtherSchemesAreNotRouted() {
        let state = ATC.State(rules: [.init(components: [.init(pattern: "page")], destination: .littleKite)])
        #expect(state.destination(for: URL(fileURLWithPath: "/tmp/page.html"), spaceIDs: spaces, opensExternalLinksInLittleKite: true) == .mostRecentSpace)
        #expect(state.destination(for: url("mailto:page@a.com"), spaceIDs: spaces, opensExternalLinksInLittleKite: true) == .mostRecentSpace)
    }

    @Test func stateRoundTripsThroughJSON() throws {
        let state = ATC.State(
            rules: [.init(components: [.init(style: .matches, pattern: "x.com")], destination: .space(work))],
            defaultDestination: .littleKite
        )
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(ATC.State.self, from: data) == state)
    }
}
