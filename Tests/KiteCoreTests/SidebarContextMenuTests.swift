import Foundation
import Testing
@testable import KiteCore

@Suite struct SidebarContextMenuTests {
    /// One space with Today tabs a…e, top to bottom, and `c` selected.
    private func today() -> (BrowserState, [UUID]) {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let space = state.spaces[0].id
        // openTab puts each new tab at the top, so open them bottom first.
        let ids = ["e", "d", "c", "b", "a"].map { state.openTab(url: URL(string: "https://\($0).example"), in: space, select: false) }
        state.spaces[0].selectedTabID = ids[2]
        return (state, Array(ids.reversed()))
    }

    @Test func archiveTabsAboveBelowAndOthersAreRelativeToTheRow() {
        let (state, t) = today()
        #expect(state.tabsToArchive(.above, relativeTo: t[2]) == [t[0], t[1]])
        #expect(state.tabsToArchive(.below, relativeTo: t[2]) == [t[3], t[4]])
        #expect(state.tabsToArchive(.others, relativeTo: t[2]) == [t[0], t[1], t[3], t[4]])
        // Arc greys out Archive Tabs Above on the top row.
        #expect(state.tabsToArchive(.above, relativeTo: t[0]).isEmpty)
        #expect(state.tabsToArchive(.below, relativeTo: t[4]).isEmpty)
    }

    @Test func archivingBelowKeepsTheRestAndFillsTheArchive() {
        var (state, t) = today()
        let archived = state.archiveTabs(.below, relativeTo: t[1])
        #expect(archived.map(\.id) == [t[2], t[3], t[4]])
        #expect(state.spaces[0].tabs.map(\.id) == [t[0], t[1]])
        #expect(state.archived.map(\.tab.id) == [t[2], t[3], t[4]])
        // The selected tab went, so the row the menu was on is selected.
        #expect(state.spaces[0].selectedTabID == t[1])
    }

    @Test func archivingOthersKeepsASplitRowTogether() {
        var (state, t) = today()
        state.spaces[0].splits = [SplitView(tabIDs: [t[1], t[2]])]
        #expect(state.tabsToArchive(.others, relativeTo: t[1]) == [t[0], t[3], t[4]])
        #expect(state.tabsToArchive(.above, relativeTo: t[2]) == [t[0]])
        state.archiveTabs(.others, relativeTo: t[2])
        #expect(state.spaces[0].tabs.map(\.id) == [t[1], t[2]])
        #expect(state.spaces[0].splits.first?.tabIDs == [t[1], t[2]])
        #expect(state.spaces[0].selectedTabID == t[2])
    }

    @Test func archiveTabsIsOnlyForTodayTabs() {
        var (state, t) = today()
        state.togglePin(tab: t[2])
        #expect(state.tabsToArchive(.others, relativeTo: t[2]).isEmpty)
        #expect(state.archiveTabs(.others, relativeTo: t[2]).isEmpty)
        #expect(state.archiveTabs(.others, relativeTo: UUID()).isEmpty)
    }

    @Test func markdownListIsOneLinkPerLine() throws {
        let a = BrowserTab(url: URL(string: "https://a.example/x"), title: "A [1]")
        var b = BrowserTab(url: URL(string: "https://b.example"), title: "Page")
        b.customTitle = "Mine"
        let blank = BrowserTab(url: nil, title: "New Tab")
        #expect(LinkFormat.markdownList([a, blank, b]) == "[A \\[1\\]](https://a.example/x)\n[Mine](https://b.example)")
        #expect(LinkFormat.markdownList([]) == "")
    }

    private func folderState() -> (BrowserState, folder: UUID, inner: UUID, tabs: [UUID]) {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let space = state.spaces[0].id
        let folder = state.createFolder(name: "Reading", inSpace: 0)
        let after = state.createFolder(name: "After", inSpace: 0)
        let a = state.openTab(url: URL(string: "https://a.example"), in: space, select: false)
        let b = state.openTab(url: URL(string: "https://b.example"), in: space, select: false)
        _ = state.moveTab(a, toFolder: folder)
        let inner = state.createNestedFolder(in: folder, name: "Inner")!
        _ = state.moveTab(b, toFolder: inner)
        state.renameTab(b, to: "Bee")
        _ = after
        return (state, folder, inner, [a, b])
    }

    @Test func newNestedFolderGoesInsideAndOpensIt() {
        var (state, folder, inner, _) = folderState()
        state.setFolderExpanded(folder, false)
        let nested = state.createNestedFolder(in: inner)
        #expect(nested != nil)
        let found = state.spaces[0].pinnedItems.folder(inner)
        #expect(found?.items.last?.id == nested)
        #expect(state.spaces[0].pinnedItems.folder(nested!)?.name == "New Folder")
        #expect(found?.isExpanded == true)
        #expect(state.createNestedFolder(in: UUID()) == nil)
    }

    @Test func duplicateFolderCopiesTheTreeRightAfterIt() throws {
        var (state, folder, _, tabs) = folderState()
        let duplicated = state.duplicateFolder(folder)
        let copyID = try #require(duplicated)
        let top = state.spaces[0].pinnedItems.map(\.id)
        #expect(top.firstIndex(of: copyID) == top.firstIndex(of: folder)! + 1)
        let copy = try #require(state.spaces[0].pinnedItems.folder(copyID))
        #expect(copy.name == "Reading")
        let copied = copy.items.tabs
        #expect(copied.map(\.url) == tabs.map { state.tab($0)?.url })
        #expect(copied.map(\.customTitle) == [nil, "Bee"])
        // Fresh ids all the way down.
        #expect(Set(copied.map(\.id)).isDisjoint(with: tabs))
        guard case .folder(let innerCopy) = copy.items.last else { Issue.record("no nested folder"); return }
        #expect(innerCopy.name == "Inner")
        #expect(state.spaces[0].pinnedItems.folder(innerCopy.id) != nil)
        #expect(state.duplicateFolder(UUID()) == nil)
    }

    @Test func duplicateANestedFolderStaysInItsParent() throws {
        var (state, folder, inner, _) = folderState()
        let duplicated = state.duplicateFolder(inner)
        let copyID = try #require(duplicated)
        #expect(state.spaces[0].pinnedItems.folder(folder)?.items.map(\.id).suffix(2) == [inner, copyID])
    }

    @Test func turningAFolderIntoASpace() throws {
        var (state, folder, _, tabs) = folderState()
        state.spaces[0].profile = "Profile 1"
        state.spaces[0].selectedTabID = tabs[0]
        let turned = state.turnFolderIntoSpace(folder)
        let id = try #require(turned)
        #expect(state.spaces.map(\.id) == [state.spaces[0].id, id])
        let space = state.spaces[1]
        #expect(space.name == "Reading" && space.profile == "Profile 1" && space.theme == state.spaces[0].theme)
        #expect(space.allTabs.map(\.id) == tabs)
        #expect(space.selectedTabID == tabs[0])
        #expect(state.selectedSpaceID == id)
        #expect(state.spaces[0].pinnedItems.folder(folder) == nil)
        #expect(state.spaces[0].allTabs.isEmpty && state.spaces[0].selectedTabID == nil)
        #expect(state.turnFolderIntoSpace(folder) == nil)
    }
}
