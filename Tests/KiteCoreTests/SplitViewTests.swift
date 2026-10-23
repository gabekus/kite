import Foundation
import Testing
@testable import KiteCore

@Suite struct SplitViewTests {
    /// Three unpinned tabs, the first (top) one selected.
    private func makeState() -> (BrowserState, [UUID]) {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        var ids: [UUID] = []
        for i in 0..<3 {
            ids.append(state.openTab(url: URL(string: "https://site\(i).com")))
        }
        ids.reverse()
        state.select(tab: ids[0])
        return (state, ids)
    }

    @Test func addingASplitPutsAnEmptyPaneNextToTheTab() throws {
        var (state, ids) = makeState()
        guard case .added(let pane) = state.addSplitPane() else { Issue.record("no pane"); return }
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [ids[0], pane])
        #expect(split.normalizedFactors == [0.5, 0.5])
        #expect(state.selectedTab?.id == pane)
        #expect(state.selectedTab?.url == nil)
        // The new pane sits right under its neighbour in the sidebar.
        #expect(state.selectedSpace.tabs.map(\.id) == [ids[0], pane, ids[1], ids[2]])
        #expect(state.visibleTabs.map(\.id) == [ids[0], pane])
    }

    @Test func aFifthPaneIsRefused() {
        var (state, _) = makeState()
        for _ in 0..<3 { _ = state.addSplitPane() }
        #expect(state.selectedSplit?.tabIDs.count == 4)
        #expect(state.addSplitPane() == .full)
        #expect(state.selectedSplit?.tabIDs.count == 4)
    }

    @Test func aPaneGoesAfterTheFocusedOneAndHalvesItsShare() throws {
        var (state, ids) = makeState()
        guard case .added(let second) = state.addSplitPane() else { return }
        state.select(tab: ids[0])
        guard case .added(let middle) = state.addSplitPane() else { return }
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [ids[0], middle, second])
        #expect(split.normalizedFactors == [0.25, 0.25, 0.5])
    }

    @Test func closingAPaneFocusesItsNeighbourAndALastPaneEndsTheSplit() {
        var (state, ids) = makeState()
        guard case .added(let pane) = state.addSplitPane() else { return }
        state.close(tab: pane)
        #expect(state.selectedTab?.id == ids[0])
        #expect(state.selectedSpace.splits.isEmpty)
        #expect(state.visibleTabs.map(\.id) == [ids[0]])
    }

    @Test func separatingLeavesTheTabOpenOnItsOwn() {
        var (state, ids) = makeState()
        guard case .added(let b) = state.addSplitPane() else { return }
        guard case .added(let c) = state.addSplitPane() else { return }
        state.separateFromSplit(tab: ids[0])
        #expect(state.selectedSpace.splits.map(\.tabIDs) == [[b, c]])
        #expect(state.selectedSpace.tabs.map(\.id) == [b, c, ids[0], ids[1], ids[2]])
        state.separateFromSplit(tab: b)
        #expect(state.selectedSpace.splits.isEmpty)
    }

    @Test func focusingPanesByNumberAndWrapping() {
        var (state, ids) = makeState()
        guard case .added(let b) = state.addSplitPane() else { return }
        state.focusPane(number: 1)
        #expect(state.selectedTab?.id == ids[0])
        state.focusPane(number: 3)
        #expect(state.selectedTab?.id == ids[0])
        state.focusAdjacentPane(offset: -1)
        #expect(state.selectedTab?.id == b)
        state.focusAdjacentPane(offset: 1)
        #expect(state.selectedTab?.id == ids[0])
    }

    @Test func tabNumbersCountASplitOnce() {
        var (state, ids) = makeState()
        guard case .added(let b) = state.addSplitPane() else { return }
        // Sidebar: [split(ids0, b)], ids1, ids2.
        state.selectTab(number: 2)
        #expect(state.selectedTab?.id == ids[1])
        state.selectAdjacentTab(offset: -1)
        // Back into the split, at the pane used last.
        #expect(state.selectedTab?.id == b)
        state.selectAdjacentTab(offset: 1)
        #expect(state.selectedTab?.id == ids[1])
    }

    @Test func pinningMovesTheWholeSplit() {
        var (state, ids) = makeState()
        guard case .added(let b) = state.addSplitPane() else { return }
        state.togglePin(tab: b)
        #expect(state.selectedSpace.pinned.map(\.id) == [ids[0], b])
        #expect(state.selectedSpace.tabs.map(\.id) == [ids[1], ids[2]])
        state.togglePin(tab: ids[0])
        #expect(state.selectedSpace.pinned.isEmpty)
        #expect(state.selectedSpace.tabs.map(\.id) == [ids[0], b, ids[1], ids[2]])
        #expect(state.selectedSpace.splits.count == 1)
    }

    @Test func favoritingAPaneTakesItOutOfTheSplit() {
        var (state, ids) = makeState()
        guard case .added(let b) = state.addSplitPane() else { return }
        state.toggleFavorite(tab: b)
        #expect(state.selectedSpace.splits.isEmpty)
        #expect(state.favorites.map(\.id) == [b])
        _ = ids
    }

    @Test func clearTodayAndArchivingDissolveSplits() {
        var (state, _) = makeState()
        _ = state.addSplitPane()
        state.clearToday()
        #expect(state.selectedSpace.splits.isEmpty)
    }

    @Test func dividerKeepsBothPanesAboveTheMinimum() throws {
        var (state, _) = makeState()
        _ = state.addSplitPane()
        let split = try #require(state.selectedSplit)
        state.moveSplitDivider(split.id, index: 0, fraction: 0.02, minimum: 0.1)
        #expect(state.selectedSplit?.normalizedFactors.first.map { abs($0 - 0.1) < 1e-9 } == true)
        state.moveSplitDivider(split.id, index: 0, fraction: 0.7, minimum: 0.1)
        #expect(state.selectedSplit?.normalizedFactors.first.map { abs($0 - 0.7) < 1e-9 } == true)
    }

    @Test func splitsSurviveARoundTripAndOldSessionsLoad() throws {
        var (state, _) = makeState()
        _ = state.addSplitPane()
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: data)
        #expect(decoded.selectedSpace.splits == state.selectedSpace.splits)

        // Sessions saved before split view have no `splits` key.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var spaces = try #require(object["spaces"] as? [[String: Any]])
        spaces[0]["splits"] = nil
        object["spaces"] = spaces
        let old = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.selectedSpace.splits.isEmpty)
    }
}

@Suite struct SidebarGroupTests {
    @Test func aSplitIsOneRowAndMovesAsOne() {
        let ids = (0..<5).map { _ in UUID() }
        let split = SplitView(tabIDs: [ids[1], ids[2]])
        let groups = SidebarGroup.group(ids, splits: [split])
        #expect(groups.map(\.indices) == [[0], [1, 2], [3], [4]])
        #expect(groups[1].id == split.id)

        // Dragging the split row below the last row moves both tabs to the end.
        let (items, target) = SidebarGroup.itemMove(groups, from: [1], to: 4, itemCount: 5)
        #expect(items == IndexSet([1, 2]))
        #expect(target == 5)
        // Dragging the last tab above the split lands before its first member.
        let (single, before) = SidebarGroup.itemMove(groups, from: [3], to: 1, itemCount: 5)
        #expect(single == IndexSet([4]))
        #expect(before == 1)
    }
}
