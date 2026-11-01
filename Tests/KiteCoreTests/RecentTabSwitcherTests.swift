import Foundation
import Testing
@testable import KiteCore

@Suite struct RecentTabSwitcherTests {
    /// Four tabs in one space, used in the order 0, 1, 2, 3 (3 is selected), plus one in another space.
    private func makeState() -> (BrowserState, [UUID], UUID) {
        var state = BrowserState(spaces: [
            Space(name: "A", icon: "a", theme: Theme.presets[0]),
            Space(name: "B", icon: "b", theme: Theme.presets[0]),
        ])
        state.selectedSpaceID = state.spaces[1].id
        let other = state.openTab(url: URL(string: "https://other.com"), now: Date(timeIntervalSince1970: 0))
        state.selectedSpaceID = state.spaces[0].id
        var ids: [UUID] = []
        for i in 0..<4 {
            ids.append(state.openTab(url: URL(string: "https://site\(i).com"), now: Date(timeIntervalSince1970: Double(i))))
        }
        for (i, id) in ids.enumerated() { state.select(tab: id, now: Date(timeIntervalSince1970: Double(10 + i))) }
        return (state, ids, other)
    }

    @Test func listsTheSpacesTabsMostRecentFirst() throws {
        let (state, ids, other) = makeState()
        let switcher = try #require(RecentTabSwitcher(state: state))
        #expect(switcher.items == [ids[3], ids[2], ids[1], ids[0]])
        #expect(!switcher.items.contains(other))
        #expect(switcher.focusedID == ids[2])
    }

    @Test func backwardStartsAtTheLeastRecentTab() throws {
        let (state, ids, _) = makeState()
        let switcher = try #require(RecentTabSwitcher(state: state, forward: false))
        #expect(switcher.focusedID == ids[0])
    }

    @Test func cyclingGoesDeeperAndWraps() throws {
        let (state, ids, _) = makeState()
        var switcher = try #require(RecentTabSwitcher(state: state))
        switcher.cycle(forward: true)
        #expect(switcher.focusedID == ids[1])
        switcher.cycle(forward: true)
        switcher.cycle(forward: true)
        #expect(switcher.focusedID == ids[3])
        switcher.cycle(forward: false)
        #expect(switcher.focusedID == ids[0])
    }

    @Test func closingTheHighlightedTabMovesToTheNext() throws {
        let (state, ids, _) = makeState()
        var switcher = try #require(RecentTabSwitcher(state: state))
        let first = switcher.remove(ids[2])
        #expect(first)
        #expect(switcher.focusedID == ids[1])
        switcher.cycle(forward: true)
        let second = switcher.remove(ids[0])
        #expect(second)
        #expect(switcher.focusedID == ids[1])
        let last = switcher.remove(ids[1])
        #expect(!last)
    }

    @Test func needsTwoTabs() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        _ = state.openTab(url: URL(string: "https://one.com"))
        #expect(RecentTabSwitcher(state: state) == nil)
    }
}
