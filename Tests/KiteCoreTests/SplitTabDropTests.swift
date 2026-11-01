import Foundation
import Testing
@testable import KiteCore

@Suite struct SplitTabDropTests {
    private func makeState(_ count: Int = 4) -> (BrowserState, [UUID]) {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        var ids: [UUID] = []
        for i in 0..<count {
            ids.append(state.openTab(url: URL(string: "https://site\(i).com")))
        }
        ids.reverse()
        state.select(tab: ids[0])
        return (state, ids)
    }

    // MARK: Regions (Arc's FUN_100a45034 / 453dc / 45484)

    @Test func aSinglePageSplitsLeftOrRightOfItsMiddleTenth() {
        func region(_ x: Double) -> SplitTabDropRegion {
            SplitTabDrop.region(x: x, y: 400, width: 1000, height: 800, paneCount: 1, orientation: .horizontal)
        }
        #expect(region(10) == .leading)
        #expect(region(449) == .leading)
        #expect(region(500) == SplitTabDropRegion.none)
        #expect(region(551) == .trailing)
        #expect(region(990) == .trailing)
        // No top or bottom bands unless vertical drops are allowed.
        #expect(SplitTabDrop.region(x: 500, y: 5, width: 1000, height: 800, paneCount: 1, orientation: .horizontal) == SplitTabDropRegion.none)
    }

    @Test func withVerticalDropsASinglePageHasTopAndBottomBands() {
        func region(_ x: Double, _ y: Double) -> SplitTabDropRegion {
            SplitTabDrop.region(x: x, y: y, width: 1000, height: 800, paneCount: 1, orientation: .horizontal, verticalAllowed: true)
        }
        #expect(region(500, 49) == .top)
        #expect(region(500, 751) == .bottom)
        #expect(region(399, 400) == .leading)
        #expect(region(450, 400) == SplitTabDropRegion.none)
        #expect(region(601, 400) == .trailing)
    }

    @Test func splitPanesTakeDropsNearTheirEndsAlongTheAxis() {
        func region(_ x: Double, _ y: Double, _ o: SplitOrientation) -> SplitTabDropRegion {
            SplitTabDrop.region(x: x, y: y, width: 600, height: 800, paneCount: 2, orientation: o)
        }
        #expect(region(79, 400, .horizontal) == .leading)
        #expect(region(81, 400, .horizontal) == SplitTabDropRegion.none)
        #expect(region(521, 400, .horizontal) == .trailing)
        #expect(region(300, 10, .horizontal) == SplitTabDropRegion.none)
        // A narrow pane: a third of its width.
        #expect(SplitTabDrop.region(x: 65, y: 400, width: 200, height: 800, paneCount: 3, orientation: .horizontal) == .leading)
        #expect(SplitTabDrop.region(x: 68, y: 400, width: 200, height: 800, paneCount: 3, orientation: .horizontal) == SplitTabDropRegion.none)
        #expect(region(300, 49, .vertical) == .top)
        #expect(region(300, 751, .vertical) == .bottom)
        #expect(region(10, 400, .vertical) == SplitTabDropRegion.none)
    }

    @Test func theSlotIsAnEqualShareTakenInProportion() {
        let one = SplitTabDrop.slot(factors: [1], insertingAt: 0)
        #expect(one.start == 0 && one.length == 0.5)
        let middle = SplitTabDrop.slot(factors: [0.5, 0.5], insertingAt: 1)
        #expect(abs(middle.start - 1.0 / 3) < 1e-9 && abs(middle.length - 1.0 / 3) < 1e-9)
        let end = SplitTabDrop.slot(factors: [0.75, 0.25], insertingAt: 2)
        #expect(abs(end.start - 2.0 / 3) < 1e-9)
    }

    // MARK: Dropping

    @Test func droppingATabOnASinglePageMakesASplitAndMovesTheTab() throws {
        var (state, ids) = makeState()
        let outcome = state.dropSidebarItems([ids[2]], besidePane: ids[0], before: false)
        #expect(outcome == .moved)
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [ids[0], ids[2]])
        #expect(split.orientation == .horizontal)
        #expect(split.normalizedFactors == [0.5, 0.5])
        #expect(state.selectedTab?.id == ids[2])
        // The tab left its place: the split's panes sit together in the list.
        let order = state.selectedSpace.tabs.map(\.id)
        let a = try #require(order.firstIndex(of: ids[0]))
        #expect(order[a + 1] == ids[2])
    }

    @Test func droppingBeforePutsTheNewPaneFirst() throws {
        var (state, ids) = makeState()
        state.dropSidebarItems([ids[3]], besidePane: ids[0], before: true)
        #expect(try #require(state.selectedSplit).tabIDs == [ids[3], ids[0]])
    }

    @Test func aPaneJoiningASplitTakesAnEqualShareFromTheOthersInProportion() throws {
        var (state, ids) = makeState()
        state.dropSidebarItems([ids[1]], besidePane: ids[0], before: false)
        var split = try #require(state.selectedSplit)
        let s = state.selectedSpaceIndex
        let i = try #require(state.spaces[s].splits.firstIndex { $0.id == split.id })
        state.spaces[s].splits[i].widthFactors = [0.75, 0.25]
        state.spaces[s].splits[i].orientation = .vertical
        state.dropSidebarItems([ids[2]], besidePane: ids[0], before: false)
        split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [ids[0], ids[2], ids[1]])
        #expect(split.orientation == .vertical)
        let f = split.normalizedFactors
        #expect(abs(f[0] - 0.5) < 1e-9 && abs(f[1] - 1.0 / 3) < 1e-9 && abs(f[2] - 1.0 / 6) < 1e-9)
    }

    @Test func refusesTabsAlreadyOnScreenFoldersFavoritesAndAFullSplit() throws {
        var (state, ids) = makeState(6)
        // The page on screen can't split with itself.
        #expect(!state.canDropSidebarItems([ids[0]], besidePane: ids[0]))
        // Only panes on screen take drops.
        #expect(!state.canDropSidebarItems([ids[2]], besidePane: ids[1]))
        state.dropSidebarItems([ids[1]], besidePane: ids[0], before: false)
        let split = try #require(state.selectedSplit)
        // A split row stands for the split: dragging it onto its own panes does nothing.
        #expect(!state.canDropSidebarItems([split.id], besidePane: ids[0]))
        state.dropSidebarItems([ids[2]], besidePane: ids[1], before: false)
        state.dropSidebarItems([ids[3]], besidePane: ids[2], before: false)
        #expect(state.visibleTabs.count == SplitView.maxPanes)
        #expect(!state.canDropSidebarItems([ids[4]], besidePane: ids[0]))
        #expect(state.dropSidebarItems([ids[4]], besidePane: ids[0], before: false) == nil)
    }

    @Test func refusesFavorites() {
        var (state, ids) = makeState()
        state.dropSidebarItems([ids[2]], on: .favorites(before: nil))
        #expect(state.location(of: ids[2])?.section == .favorite)
        #expect(!state.canDropSidebarItems([ids[2]], besidePane: ids[0]))
    }
}
