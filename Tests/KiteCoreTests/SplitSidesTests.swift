import Foundation
import Testing
@testable import KiteCore

@Suite struct SplitSidesTests {
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

    @Test func aSinglePageTakesEverySide() {
        let (state, _) = makeState()
        #expect(state.splitSides == Set(SplitEdge.allCases))
    }

    @Test func addRightSplitPutsAnEmptyPaneAfterTheFocusedPage() throws {
        var (state, ids) = makeState()
        guard case .added(let pane) = state.addSplitPane(side: .trailing) else { Issue.record("no pane"); return }
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [ids[0], pane])
        #expect(split.orientation == .horizontal)
        #expect(split.normalizedFactors == [0.5, 0.5])
        #expect(state.selectedTab?.id == pane)
        #expect(state.selectedTab?.url == nil)
    }

    @Test func addLeftSplitPutsThePaneFirstInThePanesAndTheSidebar() throws {
        var (state, ids) = makeState()
        guard case .added(let pane) = state.addSplitPane(side: .leading) else { Issue.record("no pane"); return }
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [pane, ids[0]])
        #expect(split.orientation == .horizontal)
        let order = state.selectedSpace.tabs.map(\.id)
        let p = try #require(order.firstIndex(of: pane))
        #expect(order[p + 1] == ids[0])
    }

    @Test func addTopAndBottomMakeATopBottomSplit() throws {
        var (state, ids) = makeState()
        guard case .added(let top) = state.addSplitPane(side: .top) else { Issue.record("no pane"); return }
        #expect(state.selectedSplit?.orientation == .vertical)
        #expect(state.selectedSplit?.tabIDs == [top, ids[0]])
        #expect(state.splitSides == [.top, .bottom])
        // Focus back on the page: a bottom split goes right under it, halving its share.
        state.select(tab: ids[0])
        guard case .added(let bottom) = state.addSplitPane(side: .bottom) else { Issue.record("no pane"); return }
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [top, ids[0], bottom])
        #expect(split.normalizedFactors == [0.5, 0.25, 0.25])
    }

    @Test func aSideOffTheSplitsAxisAddsNothing() throws {
        var (state, _) = makeState()
        _ = state.addSplitPane(side: .trailing)
        let before = try #require(state.selectedSplit)
        #expect(state.addSplitPane(side: .top) == .full)
        #expect(state.addSplitPane(side: .bottom) == .full)
        #expect(state.selectedSplit == before)
    }

    @Test func aFullSplitTakesNoSide() {
        var (state, _) = makeState()
        for _ in 0..<3 { _ = state.addSplitPane(side: .trailing) }
        #expect(state.selectedSplit?.tabIDs.count == 4)
        #expect(state.splitSides.isEmpty)
        #expect(state.addSplitPane(side: .leading) == .full)
    }

    @Test func addLeftSplitOnAPinnedTabKeepsThePinnedOrder() throws {
        var (state, ids) = makeState()
        state.togglePin(tab: ids[0])
        state.select(tab: ids[0])
        guard case .added(let pane) = state.addSplitPane(side: .leading) else { Issue.record("no pane"); return }
        #expect(state.selectedSplit?.tabIDs == [pane, ids[0]])
        let pinned = state.selectedSpace.pinnedItems.tabs.map(\.id)
        let p = try #require(pinned.firstIndex(of: pane))
        #expect(pinned[p + 1] == ids[0])
    }

    @Test func noTabNoPane() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        #expect(state.addSplitPane(side: .leading) == .noTab)
    }
}
