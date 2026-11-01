import Foundation
import Testing
@testable import KiteCore

@Suite struct SplitLayoutTests {
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

    private let link = URL(string: "https://dropped.example/page")!

    @Test func aSinglePageTakesDropsOnEveryEdge() {
        let (state, _) = makeState()
        #expect(state.splitDropEdges == Set(SplitEdge.allCases))
    }

    @Test func droppingOnTheBottomMakesATopBottomSplit() throws {
        var (state, ids) = makeState()
        guard case .added(let pane) = state.openInSplit(url: link, edge: .bottom) else { Issue.record("no pane"); return }
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [ids[0], pane])
        #expect(split.orientation == .vertical)
        #expect(split.normalizedFactors == [0.5, 0.5])
        #expect(state.selectedTab?.id == pane)
        #expect(state.selectedTab?.url == link)
    }

    @Test func droppingOnTheLeadingEdgePutsThePaneFirst() throws {
        var (state, ids) = makeState()
        guard case .added(let pane) = state.openInSplit(url: link, edge: .leading) else { Issue.record("no pane"); return }
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [pane, ids[0]])
        #expect(split.orientation == .horizontal)
    }

    @Test func aSplitTakesDropsOnlyAlongItsAxisAndTheNewPaneGetsAnEqualShare() throws {
        var (state, ids) = makeState()
        _ = state.openInSplit(url: link, edge: .trailing)
        #expect(state.splitDropEdges == [.leading, .trailing])
        #expect(state.openInSplit(url: link, edge: .top) == .full)
        let splitID = try #require(state.selectedSplit?.id)
        state.moveSplitDivider(splitID, index: 0, fraction: 0.75)
        guard case .added(let third) = state.openInSplit(url: link, edge: .trailing) else { Issue.record("no pane"); return }
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs.first == ids[0])
        #expect(split.tabIDs.last == third)
        let factors = split.normalizedFactors
        #expect(abs(factors[0] - 0.5) < 1e-9)
        #expect(abs(factors[1] - 1.0 / 6) < 1e-9)
        #expect(abs(factors[2] - 1.0 / 3) < 1e-9)
    }

    @Test func aFullSplitTakesNoDrops() {
        var (state, _) = makeState()
        for _ in 0..<3 { _ = state.addSplitPane() }
        #expect(state.splitDropEdges.isEmpty)
        #expect(state.openInSplit(url: link, edge: .trailing) == .full)
        #expect(state.selectedSplit?.tabIDs.count == 4)
    }

    @Test func addVerticalSplitAndConvertBack() throws {
        var (state, _) = makeState()
        guard case .added = state.addVerticalSplitPane() else { Issue.record("no pane"); return }
        let split = try #require(state.selectedSplit)
        #expect(split.orientation == .vertical)
        state.setSplitOrientation(split.id, .horizontal)
        #expect(state.selectedSplit?.orientation == .horizontal)
        #expect(state.selectedSplit?.normalizedFactors == split.normalizedFactors)
    }

    @Test func orientationSurvivesARoundTrip() throws {
        var (state, _) = makeState()
        _ = state.openInSplit(url: link, edge: .top)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: data)
        #expect(decoded.selectedSplit?.orientation == .vertical)
    }
}

@Suite struct LinkClickTests {
    private let link = URL(string: "https://clicked.example/page")!

    private func makeState() -> (BrowserState, [UUID]) {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        var ids: [UUID] = []
        for i in 0..<3 { ids.append(state.openTab(url: URL(string: "https://site\(i).com"))) }
        ids.reverse()
        state.select(tab: ids[0])
        return (state, ids)
    }

    @Test func optionCommandClickOpensInSplitViewAndShiftWins() {
        #expect(LinkClick.commandClickDestination(shift: false, option: false) == .backgroundTab)
        #expect(LinkClick.commandClickDestination(shift: false, option: true) == .splitView)
        #expect(LinkClick.commandClickDestination(shift: true, option: false) == .foregroundTab)
        #expect(LinkClick.commandClickDestination(shift: true, option: true) == .foregroundTab)
    }

    @Test func optionCommandClickOpensLittleKiteWhileTheSettingIsOn() {
        #expect(LinkClick.commandClickDestination(shift: false, option: true, opensLittleKite: true) == .littleKite)
        #expect(LinkClick.commandClickDestination(shift: false, option: false, opensLittleKite: true) == .backgroundTab)
        #expect(LinkClick.commandClickDestination(shift: true, option: true, opensLittleKite: true) == .foregroundTab)
        // Arc wants ⌥ and ⌘: an ⌥-middle-click still splits.
        #expect(LinkClick.commandClickDestination(shift: false, option: true, command: false, opensLittleKite: true) == .splitView)
    }

    @Test func aLinkFromAPageMakesATwoPaneSplitWithTheLinkFocused() throws {
        var (state, ids) = makeState()
        guard case .added(let pane) = state.openLinkInSplit(url: link, from: ids[0]) else { Issue.record("no pane"); return }
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [ids[0], pane])
        #expect(state.selectedTab?.id == pane)
        #expect(state.selectedTab?.url == link)
    }

    @Test func theNewPaneGoesNextToTheClickedPaneNotTheFocusedOne() throws {
        var (state, ids) = makeState()
        guard case .added(let second) = state.openLinkInSplit(url: link, from: ids[0]) else { Issue.record("no pane"); return }
        // The click came from the first pane while the second has focus.
        guard case .added(let third) = state.openLinkInSplit(url: link, from: ids[0]) else { Issue.record("no pane"); return }
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [ids[0], third, second])
        #expect(state.selectedTab?.id == third)
    }

    @Test func aFullSplitTakesNothingAndKeepsFocus() throws {
        var (state, ids) = makeState()
        for _ in 1..<SplitView.maxPanes { _ = state.openLinkInSplit(url: link, from: ids[0]) }
        let focused = state.selectedTab?.id
        let before = state.selectedSplit?.tabIDs
        #expect(state.openLinkInSplit(url: link, from: ids[0]) == .full)
        #expect(state.selectedTab?.id == focused)
        #expect(state.selectedSplit?.tabIDs == before)
    }
}
