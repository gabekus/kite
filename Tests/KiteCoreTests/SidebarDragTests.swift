import Foundation
import Testing
@testable import KiteCore

@Suite struct SidebarDragTests {
    /// Two spaces. Home: Today tabs t1 t2 t3 (top to bottom), nothing pinned. Work: one Today tab w1.
    private func make() -> (BrowserState, home: UUID, work: UUID, t: [UUID], w1: UUID) {
        var state = BrowserState(spaces: [
            Space(name: "Home", icon: "🏠", theme: Theme.presets[0]),
            Space(name: "Work", icon: "💼", theme: Theme.presets[1]),
        ])
        let home = state.spaces[0].id, work = state.spaces[1].id
        let t3 = state.openTab(url: URL(string: "https://three.example"), in: home)
        let t2 = state.openTab(url: URL(string: "https://two.example"), in: home)
        let t1 = state.openTab(url: URL(string: "https://one.example"), in: home)
        let w1 = state.openTab(url: URL(string: "https://work.example"), in: work, select: false)
        state.selectSpace(home)
        return (state, home, work, [t1, t2, t3], w1)
    }

    private func today(_ state: BrowserState, _ s: Int) -> [UUID] { state.spaces[s].tabs.map(\.id) }

    @Test func reordersToday() {
        var (state, home, _, t, _) = make()
        #expect(state.dropSidebarItems([t[2]], on: .unpinned(space: home, before: t[0])) == .moved)
        #expect(today(state, 0) == [t[2], t[0], t[1]])
        state.dropSidebarItems([t[2]], on: .unpinned(space: home, before: nil))
        #expect(today(state, 0) == [t[0], t[1], t[2]])
    }

    @Test func droppingInItsOwnGapChangesNothing() {
        var (state, home, _, t, _) = make()
        state.dropSidebarItems([t[1]], on: .unpinned(space: home, before: t[1]))
        #expect(today(state, 0) == t)
    }

    @Test func pinningByDragSetsThePinnedURL() throws {
        var (state, home, _, t, _) = make()
        #expect(state.dropSidebarItems([t[1]], on: .pinned(space: home, folder: nil, before: nil)) == .pinned(count: 1))
        #expect(state.spaces[0].pinned.map(\.id) == [t[1]])
        #expect(state.spaces[0].pinned[0].pinnedURL?.host() == "two.example")
        #expect(state.dropSidebarItems([t[1]], on: .unpinned(space: home, before: t[2])) == .unpinned(count: 1))
        #expect(today(state, 0) == t)
        #expect(try #require(state.tab(t[1])).pinnedURL == nil)
    }

    @Test func intoAndOutOfFolders() {
        var (state, home, _, t, _) = make()
        let folder = state.createFolder(name: "F", inSpace: 0)
        let inner = state.createFolder(name: "Inner", inSpace: 0)
        state.dropSidebarItems([t[0]], on: .folder(folder))
        state.dropSidebarItems([t[1]], on: .pinned(space: home, folder: folder, before: t[0]))
        #expect(state.folders(inSpace: 0).first { $0.id == folder }?.items.map(\.id) == [t[1], t[0]])
        // A folder goes into another folder, but never into itself or its own child.
        #expect(state.dropSidebarItems([inner], on: .folder(folder)) == .moved)
        #expect(!state.canDrop([folder], on: .folder(inner)))
        #expect(!state.canDrop([folder], on: .folder(folder)))
        #expect(!state.canDrop([folder], on: .pinned(space: home, folder: inner, before: nil)))
        // Folders stay pinned.
        #expect(!state.canDrop([folder], on: .unpinned(space: home, before: nil)))
        #expect(!state.canDrop([folder], on: .favorites(before: nil)))
        // Out again to the top level.
        state.dropSidebarItems([t[0]], on: .pinned(space: home, folder: nil, before: folder))
        #expect(state.spaces[0].pinnedItems.map(\.id) == [t[0], folder])
    }

    @Test func favoritesTakeTabsFromAnywhereAndReorder() {
        var (state, home, _, t, w1) = make()
        state.dropSidebarItems([t[0]], on: .favorites(before: nil))
        state.dropSidebarItems([w1], on: .favorites(before: t[0]))
        #expect(state.favorites.map(\.id) == [w1, t[0]])
        state.dropSidebarItems([w1], on: .favorites(before: nil))
        #expect(state.favorites.map(\.id) == [t[0], w1])
        // Out of the favorites into a space.
        state.dropSidebarItems([w1], on: .unpinned(space: home, before: t[1]))
        #expect(today(state, 0) == [w1, t[1], t[2]])
        #expect(state.favorites.map(\.id) == [t[0]])
    }

    @Test func toAnotherSpaceSelectsSomethingElse() {
        var (state, home, work, t, w1) = make()
        state.spaces[0].selectedTabID = t[0]
        let outcome = state.dropSidebarItems([t[0]], on: .space(work))
        #expect(outcome == .movedToSpace(work, tabID: t[0]))
        #expect(today(state, 1) == [t[0], w1])
        #expect(state.spaces[0].selectedTabID == t[1])
        #expect(state.selectedSpaceID == home)
    }

    @Test func splitsMoveAsOne() {
        var (state, home, work, t, w1) = make()
        state.spaces[0].splits = [SplitView(tabIDs: [t[0], t[1]])]
        let split = state.spaces[0].splits[0].id
        #expect(state.sidebarDragID(for: t[1]) == split)
        state.dropSidebarItems([split], on: .unpinned(space: home, before: nil))
        #expect(today(state, 0) == [t[2], t[0], t[1]])
        state.dropSidebarItems([split], on: .unpinned(space: work, before: w1))
        #expect(today(state, 1) == [t[0], t[1], w1])
        #expect(state.spaces[1].splits.map(\.id) == [split])
        #expect(state.spaces[0].splits.isEmpty)
    }

    @Test func favoritesHoldSplits() throws {
        var (state, home, _, t, _) = make()
        state.spaces[0].splits = [SplitView(tabIDs: [t[0], t[1]])]
        let split = state.spaces[0].splits[0].id
        state.dropSidebarItems([split], on: .favorites(before: nil))
        #expect(state.favorites.map(\.id) == [t[0], t[1]])
        #expect(state.favoriteSplits.map(\.id) == [split])
        #expect(state.spaces[0].splits.isEmpty)
        // Shown in whichever space is on screen, and the split works as one there.
        state.select(tab: t[1])
        #expect(state.selectedSplit?.id == split)
        #expect(state.visibleTabs.map(\.id) == [t[0], t[1]])
        state.moveSplitDivider(split, index: 0, fraction: 0.25)
        #expect(try #require(state.favoriteSplits.first).normalizedFactors.first.map { abs($0 - 0.25) < 0.001 } == true)
        // Reordering favorites keeps the split's panes together.
        state.dropSidebarItems([t[2]], on: .favorites(before: split))
        #expect(state.favorites.map(\.id) == [t[2], t[0], t[1]])
        // Removing a pane from the favorites ends the split.
        state.dropSidebarItems([t[1]], on: .unpinned(space: home, before: nil))
        #expect(state.favoriteSplits.isEmpty)
        // And a favorite split survives a save.
        let x = state.openTab(url: URL(string: "https://x.example"), in: home)
        state.dropSidebarItems([x], on: .split(with: t[1], side: .right))
        state.dropSidebarItems([state.sidebarDragID(for: x)], on: .favorites(before: nil))
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.favoriteSplits == state.favoriteSplits)
        #expect(!decoded.favoriteSplits.isEmpty)
    }

    @Test func droppingOnATabMakesASplit() throws {
        var (state, _, _, t, _) = make()
        #expect(state.dropSidebarItems([t[2]], on: .split(with: t[0], side: .left)) == .moved)
        let split = try #require(state.spaces[0].splits.first)
        #expect(split.tabIDs == [t[2], t[0]])
        #expect(today(state, 0) == [t[2], t[0], t[1]])
        #expect(state.spaces[0].selectedTabID == t[2])
        // A third pane joins on the right of the one it was dropped on.
        state.dropSidebarItems([t[1]], on: .split(with: t[2], side: .right))
        #expect(state.spaces[0].splits.first?.tabIDs == [t[2], t[1], t[0]])
        #expect(state.spaces[0].splits.first?.normalizedFactors.allSatisfy { abs($0 - 1.0 / 3) < 0.001 } == true)
    }

    @Test func splitsStopAtFourPanes() {
        var (state, home, _, t, _) = make()
        let t4 = state.openTab(url: URL(string: "https://four.example"), in: home)
        let t5 = state.openTab(url: URL(string: "https://five.example"), in: home)
        state.spaces[0].splits = [SplitView(tabIDs: [t[0], t[1], t[2], t4])]
        state.spaces[0].tabs = state.spaces[0].tabs.sorted { a, _ in a.id != t5 }
        #expect(!state.canDrop([t5], on: .split(with: t[0], side: .left)))
    }

    @Test func splitInPinnedSection() throws {
        var (state, home, _, t, _) = make()
        state.dropSidebarItems([t[0], t[1]], on: .pinned(space: home, folder: nil, before: nil))
        state.dropSidebarItems([t[2]], on: .split(with: t[1], side: .left))
        #expect(state.spaces[0].pinnedItems.map(\.id) == [t[0], t[2], t[1]])
        #expect(try #require(state.spaces[0].splits.first).tabIDs == [t[2], t[1]])
    }
}
