import Foundation
import Testing
@testable import KiteCore

@Suite struct SplitPaneMenuTests {
    /// Three tabs, the first two in a side-by-side split (the first focused).
    private func makeState() -> (BrowserState, [UUID]) {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        var ids: [UUID] = []
        for i in 0..<3 {
            ids.append(state.openTab(url: URL(string: "https://site\(i).com")))
        }
        ids.reverse()
        state.spaces[0].tabs = ids.compactMap { state.tab($0) }
        state.spaces[0].splits = [SplitView(tabIDs: [ids[0], ids[1]], widthFactors: [0.3, 0.7])]
        state.select(tab: ids[0])
        return (state, ids)
    }

    private func titles(_ menu: [(item: SplitPaneMenuItem, enabled: Bool)]) -> [String] {
        menu.map { entry in entry.item.title.map { entry.enabled ? $0 : "(\($0))" } ?? "---" }
    }

    @Test func aSideBySidePaneGetsLeftRightItems() {
        let (state, ids) = makeState()
        #expect(titles(state.splitPaneMenu(for: ids[0])) == [
            "(Move Left)", "Move Right", "---", "Add Left Split", "Add Right Split", "---",
            "Separate Tab from Split", "---", "Convert to Vertical Split View",
        ])
        #expect(titles(state.splitPaneMenu(for: ids[1])).prefix(2) == ["Move Left", "(Move Right)"])
    }

    @Test func aTopBottomPaneGetsUpDownItems() {
        var (state, ids) = makeState()
        state.spaces[0].splits[0].orientation = .vertical
        #expect(titles(state.splitPaneMenu(for: ids[1])) == [
            "Move Up", "(Move Down)", "---", "Add Top Split", "Add Bottom Split", "---",
            "Separate Tab from Split", "---", "Convert to Horizontal Split View",
        ])
    }

    @Test func aFullSplitCantAddMore() {
        var (state, ids) = makeState()
        state.spaces[0].splits[0] = SplitView(tabIDs: [ids[0], ids[1], ids[2], state.openTab(url: nil)])
        let menu = state.splitPaneMenu(for: ids[0])
        #expect(menu.filter { if case .add = $0.item { true } else { false } }.allSatisfy { !$0.enabled })
    }

    @Test func noMenuOutsideASplit() {
        let (state, ids) = makeState()
        #expect(state.splitPaneMenu(for: ids[2]).isEmpty)
    }

    @Test func moveRightSwapsPanesWithTheirSharesAndTheSidebarOrder() throws {
        var (state, ids) = makeState()
        let moved = state.moveSplitPane(ids[0], toward: .trailing)
        #expect(moved)
        let split = try #require(state.selectedSplit)
        #expect(split.tabIDs == [ids[1], ids[0]])
        #expect(split.normalizedFactors.map { ($0 * 10).rounded() / 10 } == [0.7, 0.3])
        #expect(state.selectedSpace.tabs.map(\.id) == [ids[1], ids[0], ids[2]])
        #expect(state.selectedTab?.id == ids[0])
    }

    @Test func moveStopsAtTheEndsAndOffTheAxis() {
        var (state, ids) = makeState()
        let moves = [
            state.moveSplitPane(ids[0], toward: .leading),
            state.moveSplitPane(ids[1], toward: .trailing),
            state.moveSplitPane(ids[0], toward: .bottom),
            state.moveSplitPane(ids[2], toward: .trailing),
        ]
        #expect(moves == [false, false, false, false])
        #expect(state.selectedSplit?.tabIDs == [ids[0], ids[1]])
    }

    @Test func moveUpInATopBottomSplit() {
        var (state, ids) = makeState()
        state.spaces[0].splits[0].orientation = .vertical
        let moved = state.moveSplitPane(ids[1], toward: .top)
        #expect(moved)
        #expect(state.selectedSplit?.tabIDs == [ids[1], ids[0]])
    }
}
