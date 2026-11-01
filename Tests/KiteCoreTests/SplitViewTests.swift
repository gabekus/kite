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

    @Test func cancellingAnEmptyPaneUndoesTheSplit() {
        var (state, ids) = makeState()
        guard case .added(let pane) = state.addSplitPane() else { return }
        state.cancelSplitPane(pane)
        #expect(state.selectedSpace.splits.isEmpty)
        #expect(state.selectedSpace.tabs.map(\.id) == ids)
        #expect(state.selectedTab?.id == ids[0])
        #expect(state.archived.isEmpty && state.recentlyClosed.isEmpty)
    }

    @Test func cancellingUndoesAPaneShowingAboutBlank() {
        var (state, ids) = makeState()
        guard case .added(let pane) = state.addSplitPane() else { return }
        state.update(tab: pane) { $0.url = URL(string: "about:blank") }
        state.cancelSplitPane(pane)
        #expect(state.selectedSpace.splits.isEmpty)
        #expect(state.selectedSpace.tabs.map(\.id) == ids)
    }

    @Test func cancellingKeepsAPaneThatLoadedSomething() {
        var (state, _) = makeState()
        guard case .added(let pane) = state.addSplitPane() else { return }
        state.update(tab: pane) { $0.url = URL(string: "https://example.com") }
        state.cancelSplitPane(pane)
        #expect(state.selectedSplit?.tabIDs.count == 2)
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

    @Test func expandingShowsTheFocusedPaneAloneAndKeepsTheWidths() throws {
        var (state, ids) = makeState()
        guard case .added(let b) = state.addSplitPane() else { return }
        let splitID = try #require(state.selectedSplit?.id)
        state.moveSplitDivider(splitID, index: 0, fraction: 0.25)
        state.expandSplitPane()
        var split = try #require(state.selectedSplit)
        #expect(split.expandedTabID == b)
        #expect(split.layoutFactors == [0, 1])
        // Still a split: both panes stay members and on screen's list.
        #expect(split.tabIDs == [ids[0], b])
        #expect(state.visibleTabs.map(\.id) == [ids[0], b])
        #expect(split.normalizedFactors == [0.25, 0.75])
        // Again does nothing, as in Arc.
        state.expandSplitPane()
        #expect(state.selectedSplit == split)
        // Focusing the other pane brings the old widths back.
        state.focusPane(number: 1)
        split = try #require(state.selectedSplit)
        #expect(split.expandedTabID == nil)
        #expect(split.layoutFactors == [0.25, 0.75])
    }

    @Test func expandingIsPerSplitAndSurvivesCoding() throws {
        var (state, ids) = makeState()
        guard case .added = state.addSplitPane() else { return }
        state.expandSplitPane()
        state.select(tab: ids[1])
        guard case .added = state.addSplitPane() else { return }
        #expect(state.selectedSplit?.expandedTabID == nil)
        #expect(state.selectedSpace.splits.compactMap(\.expandedTabID).count == 1)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.selectedSpace.splits.map(\.expandedTabID) == state.selectedSpace.splits.map(\.expandedTabID))
        // A split saved before this existed decodes unexpanded.
        let old = #"{"id":"\#(UUID().uuidString)","tabIDs":[],"widthFactors":[],"orientation":"horizontal"}"#
        #expect(try JSONDecoder().decode(SplitView.self, from: Data(old.utf8)).expandedTabID == nil)
    }

    @Test func focusingAHiddenPaneOrChangingTheSplitUnexpands() throws {
        var (state, ids) = makeState()
        guard case .added(let b) = state.addSplitPane() else { return }
        state.expandSplitPane()
        state.focusPane(number: 1)
        #expect(state.selectedSplit?.expandedTabID == nil)
        // Re-selecting the expanded pane itself keeps it expanded.
        state.expandSplitPane()
        state.select(tab: ids[0])
        #expect(state.selectedSplit?.expandedTabID == ids[0])
        // A new pane is shown.
        guard case .added = state.addSplitPane() else { return }
        #expect(state.selectedSplit?.expandedTabID == nil)
        // Closing the expanded pane shows the rest.
        state.select(tab: b)
        state.expandSplitPane()
        state.close(tab: b)
        #expect(state.selectedSplit?.expandedTabID == nil)
        #expect(state.selectedSplit?.layoutFactors.contains(0) == false)
        // Dragging a divider shows the split too.
        state.expandSplitPane()
        let splitID = try #require(state.selectedSplit?.id)
        state.moveSplitDivider(splitID, index: 0, fraction: 0.5)
        #expect(state.selectedSplit?.expandedTabID == nil)
    }

    @Test func expandingWithoutASplitDoesNothing() {
        var (state, _) = makeState()
        let before = state
        state.expandSplitPane()
        #expect(state == before)
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
        // Explicit, increasing times: Windows' clock can stamp makeState's selection and
        // the new pane with the same Date, and then "the pane used last" is a tie.
        let t = Date().addingTimeInterval(60)
        guard case .added(let b) = state.addSplitPane(now: t) else { return }
        // Sidebar: [split(ids0, b)], ids1, ids2.
        state.selectTab(number: 2, now: t + 1)
        #expect(state.selectedTab?.id == ids[1])
        state.selectAdjacentTab(offset: -1, now: t + 2)
        // Back into the split, at the pane used last.
        #expect(state.selectedTab?.id == b)
        state.selectAdjacentTab(offset: 1, now: t + 3)
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
