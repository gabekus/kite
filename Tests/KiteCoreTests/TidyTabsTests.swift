import Foundation
import Testing
@testable import KiteCore

@Suite struct TidyTabsTests {
    private func state(_ count: Int = 4) -> (BrowserState, [UUID]) {
        var space = Space(name: "S", icon: "🏠", theme: Theme.presets[0])
        space.tabs = (0..<count).map { BrowserTab(url: URL(string: "https://site\($0).test/"), title: "Tab \($0)") }
        return (BrowserState(spaces: [space]), space.tabs.map(\.id))
    }

    @Test func promptNumbersTabsWithTheirSiteAndWrapsThemAsUntrusted() {
        let prompt = TidyTabs.prompt(for: [
            .init(title: "Flights to Lisbon", url: URL(string: "https://www.example.com/x")),
            .init(title: "Line\nbreak", url: nil),
        ])
        #expect(prompt.contains("1: Flights to Lisbon (www.example.com)"))
        #expect(prompt.contains("2: Line break\n"))
        #expect(prompt.contains("<untrusted-page-content"))
        #expect(prompt.contains("\"Other\""))
    }

    @Test func parseReadsAFencedArrayAndSendsLeftoversToOther() {
        let reply = """
            Here you go:
            ```json
            [{"title": "Travel", "tabs": [1, 3, 3, 9]}, {"title": "Work", "tabs": [2]}]
            ```
            """
        let groups = TidyTabs.parse(reply, tabCount: 4)
        #expect(groups == [
            .init(title: "Travel", tabs: [1, 3]),
            .init(title: "Work", tabs: [2]),
            .init(title: "Other", tabs: [4]),
        ])
    }

    @Test func parseMergesSameTitlesAndRejectsASingleGroupOrJunk() {
        #expect(TidyTabs.parse(#"[{"title":"A","tabs":[1]},{"title":"a","tabs":[2]}]"#, tabCount: 2) == nil)
        #expect(TidyTabs.parse(#"[{"title":"All","tabs":[1,2,3]}]"#, tabCount: 3) == nil)
        #expect(TidyTabs.parse("no idea", tabCount: 3) == nil)
        #expect(TidyTabs.parse("[]", tabCount: 0) == nil)
        #expect(TidyTabs.parse(#"[{"name":"A","tabs":[1]},{"title":"Other","tabs":[]}]"#, tabCount: 2)
            == [.init(title: "A", tabs: [1]), .init(title: "Other", tabs: [2])])
    }

    @Test func applyPutsEachGroupTogetherUnderAHeader() throws {
        var (state, ids) = state()
        let space = state.spaces[0].id
        #expect(state.canTidyTabs(inSpace: space))
        let changed = state.applyTidy(inSpace: space, tabs: ids, groups: [
            .init(title: "Odd", tabs: [2, 4]), .init(title: "Even", tabs: [1, 3]),
        ])
        #expect(changed)
        #expect(state.spaces[0].tabs.map(\.id) == [ids[1], ids[3], ids[0], ids[2]])
        #expect(state.spaces[0].tabGroups.map(\.title) == ["Odd", "Even"])
        let header = try #require(state.tabGroupHeader(above: ids[1], inSpace: state.spaces[0]))
        #expect(header.title == "Odd")
        #expect(state.tabGroupHeader(above: ids[3], inSpace: state.spaces[0]) == nil)
        #expect(state.tabGroupHeader(above: ids[0], inSpace: state.spaces[0])?.title == "Even")
        // Everything is grouped now, so there's nothing left to tidy.
        #expect(!state.canTidyTabs(inSpace: space))
    }

    @Test func tabsOpenedWhileTidyRanStayOnTop() {
        var (state, ids) = state()
        let space = state.spaces[0].id
        let fresh = state.openTab(url: URL(string: "https://new.test/"))
        state.applyTidy(inSpace: space, tabs: ids, groups: [.init(title: "A", tabs: [1, 2]), .init(title: "B", tabs: [3, 4])])
        #expect(state.spaces[0].tabs.first?.id == fresh)
        #expect(state.tabGroupHeader(above: fresh, inSpace: state.spaces[0]) == nil)
    }

    @Test func headersFollowTheirTabsAndGoWhenEmpty() {
        var (state, ids) = state()
        let space = state.spaces[0].id
        state.applyTidy(inSpace: space, tabs: ids, groups: [.init(title: "A", tabs: [1, 2]), .init(title: "B", tabs: [3, 4])])
        _ = state.close(tab: ids[0])
        state.pruneTabGroups()
        #expect(state.tabGroupHeader(above: ids[1], inSpace: state.spaces[0])?.title == "A")
        _ = state.close(tab: ids[1])
        state.pruneTabGroups()
        #expect(state.spaces[0].tabGroups.map(\.title) == ["B"])
    }

    @Test func removeHeaderKeepsTabsAndUndoRestoresOrderAndHeaders() throws {
        var (state, ids) = state()
        let space = state.spaces[0].id
        let before = state.spaces[0].tabs.map(\.id)
        state.applyTidy(inSpace: space, tabs: ids, groups: [.init(title: "A", tabs: [4, 1]), .init(title: "B", tabs: [2, 3])])
        let group = try #require(state.spaces[0].tabGroups.first)
        state.removeTabGroupHeader(group.id)
        #expect(state.spaces[0].tabs.count == 4)
        #expect(state.spaces[0].tabGroups.map(\.title) == ["B"])
        state.restoreToday(inSpace: space, tabs: before, groups: [])
        #expect(state.spaces[0].tabs.map(\.id) == before)
        #expect(state.spaces[0].tabGroups.isEmpty)
    }

    @Test func groupsSurviveASessionRoundTrip() throws {
        var (state, ids) = state()
        state.applyTidy(inSpace: state.spaces[0].id, tabs: ids, groups: [.init(title: "A", tabs: [1, 2]), .init(title: "B", tabs: [3, 4])])
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: data)
        #expect(decoded.spaces[0].tabGroups == state.spaces[0].tabGroups)
    }

    @Test func onByDefaultLikeGabesArc() throws {
        let defaults = try #require(UserDefaults(suiteName: "tidy-\(UUID())"))
        #expect(TidyTabs.isEnabled(in: defaults))
        defaults.set(false, forKey: TidyTabs.enabledKey)
        #expect(!TidyTabs.isEnabled(in: defaults))
    }
}
