import Foundation
import Testing
@testable import KiteCore

@Suite struct TabRenameTests {
    private func state() -> (BrowserState, UUID) {
        var space = Space(name: "S", icon: "🏠", theme: Theme.presets[0])
        let tab = BrowserTab(url: URL(string: "https://example.com"), title: "Example Domain")
        space.tabs = [tab]
        space.selectedTabID = tab.id
        return (BrowserState(spaces: [space]), tab.id)
    }

    @Test func aRenamedTabShowsItsNameAndKeepsItWhenThePageTitleChanges() {
        var (state, id) = state()
        state.renameTab(id, to: "  Docs  ")
        #expect(state.tab(id)?.displayTitle == "Docs")
        state.update(tab: id) { $0.title = "A new page title" }
        #expect(state.tab(id)?.displayTitle == "Docs")
        #expect(state.tab(id)?.title == "A new page title")
    }

    @Test func anEmptyNameGoesBackToThePageTitle() {
        var (state, id) = state()
        state.renameTab(id, to: "Docs")
        state.renameTab(id, to: "   ")
        #expect(state.tab(id)?.customTitle == nil)
        #expect(state.tab(id)?.displayTitle == "Example Domain")
    }

    @Test func pinnedTabsAndFavoritesRenameToo() {
        var (state, id) = state()
        state.togglePin(tab: id)
        state.renameTab(id, to: "Pinned name")
        #expect(state.selectedSpace.pinned.first?.displayTitle == "Pinned name")
        let favorite = BrowserTab(url: URL(string: "https://mail.example.com"), title: "Inbox (3)")
        state.favorites = [favorite]
        state.renameTab(favorite.id, to: "Mail")
        #expect(state.favorites.first?.displayTitle == "Mail")
    }

    @Test func theNameSurvivesASaveAndOlderSessionsLoadWithout() throws {
        var (state, id) = state()
        state.renameTab(id, to: "Docs")
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.tab(id)?.customTitle == "Docs")

        let old = #"{"id":"\#(UUID().uuidString)","title":"Old","lastActiveAt":0}"#
        let tab = try JSONDecoder().decode(BrowserTab.self, from: Data(old.utf8))
        #expect(tab.customTitle == nil)
        #expect(tab.displayTitle == "Old")
    }

    @Test func tabSearchFindsARenamedTabByItsName() {
        var (state, id) = state()
        state.renameTab(id, to: "Reference")
        #expect(TabSearch.score("refer", state.tab(id)!) != nil)
        #expect(TabSearch.score("example", state.tab(id)!) != nil)
    }

    @Test func duplicateKeepsTheName() {
        var (state, id) = state()
        state.renameTab(id, to: "Docs")
        let copy = state.duplicate(tab: id)
        #expect(copy.flatMap { state.tab($0) }?.displayTitle == "Docs")
    }
}

@Suite struct CollapsePinnedTabsTests {
    private func state() -> (BrowserState, [UUID]) {
        var space = Space(name: "S", icon: "🏠", theme: Theme.presets[0])
        let a = BrowserTab(url: URL(string: "https://a.example"), title: "A")
        let b = BrowserTab(url: URL(string: "https://b.example"), title: "B")
        let c = BrowserTab(url: URL(string: "https://c.example"), title: "C")
        space.pinnedItems = [.tab(a), .folder(TabFolder(name: "F", items: [.tab(b)]))]
        space.tabs = [c]
        space.selectedTabID = c.id
        return (BrowserState(spaces: [space]), [a.id, b.id, c.id])
    }

    @Test func collapsingHidesThePinnedTabsAndExpandingBringsThemBack() {
        var (state, _) = state()
        let space = state.selectedSpaceID
        #expect(state.shownPinnedItems(in: state.selectedSpace).count == 2)
        state.togglePinnedSection(space)
        #expect(state.isPinnedSectionCollapsed(space))
        #expect(state.shownPinnedItems(in: state.selectedSpace).isEmpty)
        state.togglePinnedSection(space)
        #expect(!state.isPinnedSectionCollapsed(space))
        #expect(state.shownPinnedItems(in: state.selectedSpace).count == 2)
    }

    @Test func collapsedKeepsTheSelectedPinnedTabEvenFromAFolder() {
        var (state, ids) = state()
        state.togglePinnedSection(state.selectedSpaceID)
        state.select(tab: ids[1])
        let shown = state.shownPinnedItems(in: state.selectedSpace)
        #expect(shown.map(\.id) == [ids[1]])
    }

    @Test func itIsPerSpaceAndSaved() throws {
        var (state, _) = state()
        _ = state.addSpace(name: "Two", icon: "💼", theme: Theme.presets[1])
        let first = state.spaces[0].id
        state.togglePinnedSection(first)
        #expect(!state.isPinnedSectionCollapsed(state.spaces[1].id))
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.isPinnedSectionCollapsed(first))
        state.togglePinnedSection(UUID())
        #expect(state.spacesWithCollapsedPinnedSections == [first])
    }
}
