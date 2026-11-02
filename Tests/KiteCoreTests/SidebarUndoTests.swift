import Foundation
import Testing
@testable import KiteCore

/// Edit › Undo and Redo of sidebar changes (SidebarUndo): what each step is called, and that
/// undoing and redoing put the sidebar back without losing what changed since.
@Suite struct SidebarUndoTests {
    private func url(_ host: String) -> URL { URL(string: "https://\(host)")! }

    /// Runs `change`, then returns the step's name and its before/after snapshots.
    private func step(_ state: inout BrowserState, _ change: (inout BrowserState) -> Void)
        -> (name: String?, before: SidebarSnapshot, after: SidebarSnapshot) {
        let old = state
        change(&state)
        let name = SidebarUndo.isUndoable(from: old, to: state) ? SidebarUndo.actionName(from: old, to: state) : nil
        return (name, SidebarSnapshot(old), SidebarSnapshot(state))
    }

    @Test func closingATabIsArchiveTabAndUndoBringsItBackSelected() {
        var state = BrowserState.makeDefault()
        let a = state.openTab(url: url("a.com"))
        let b = state.openTab(url: url("b.com"))
        let order = state.selectedSpace.tabs.map(\.id)
        let s = step(&state) { $0.close(tab: b) }
        #expect(s.name == "Archive Tab")
        #expect(state.archived.contains { $0.tab.id == b })

        state.restoreSidebar(s.before, other: s.after)
        #expect(state.selectedSpace.tabs.map(\.id) == order)
        #expect(state.selectedTab?.id == b)
        #expect(!state.archived.contains { $0.tab.id == b })
        #expect(!state.recentlyClosed.contains { $0.tab.id == b })

        // Redo archives it again.
        state.restoreSidebar(s.after, other: s.before)
        #expect(!state.selectedSpace.tabs.contains { $0.id == b })
        #expect(state.archived.contains { $0.tab.id == b })
        #expect(state.recentlyClosed.contains { $0.tab.id == b })
        #expect(state.selectedTab?.id == a)
    }

    @Test func pageChangesSinceTheStepSurviveUndo() {
        var state = BrowserState.makeDefault()
        let a = state.openTab(url: url("a.com"))
        let s = step(&state) { $0.togglePin(tab: a) }
        #expect(s.name == "Move Item")
        // The page moves on after pinning.
        state.update(tab: a) { $0.url = self.url("a.com/next"); $0.title = "Next" }
        state.restoreSidebar(s.before, other: s.after)
        #expect(state.selectedSpace.tabs.first?.id == a)
        #expect(state.tab(a)?.url == url("a.com/next"))
        #expect(state.tab(a)?.title == "Next")
    }

    @Test func tabsOpenedSinceTheStepStay() {
        var state = BrowserState.makeDefault()
        let a = state.openTab(url: url("a.com"))
        let s = step(&state) { $0.togglePin(tab: a) }
        // Claude (or anything else) opens a tab after the user's step.
        let later = state.openTab(url: url("later.com"), select: false)
        state.restoreSidebar(s.before, other: s.after)
        #expect(state.tab(later) != nil)
        #expect(state.tab(a) != nil)
        #expect(state.location(of: a)?.section == .unpinned)
    }

    @Test func closingPinnedAndFavoriteTabsUsesArcsNames() {
        var state = BrowserState.makeDefault()
        let a = state.openTab(url: url("a.com"))
        let b = state.openTab(url: url("b.com"))
        state.togglePin(tab: a)
        state.toggleFavorite(tab: b)
        #expect(step(&state) { _ = $0.removePinnedTab(a) }.name == "Remove Pin")
        let removeFavorite = step(&state) { state in
            for profile in state.favoritesByProfile.keys { state.favoritesByProfile[profile]?.removeAll { $0.id == b } }
        }
        #expect(removeFavorite.name == "Remove Favorite")
    }

    @Test func newTabUndoesByClosing() {
        var state = BrowserState.makeDefault()
        let s = step(&state) { _ = $0.openTab(url: self.url("a.com")) }
        #expect(s.name == "New Tab")
        let id = state.selectedTab!.id
        state.restoreSidebar(s.before, other: s.after)
        #expect(state.tab(id) == nil)
        state.restoreSidebar(s.after, other: s.before)
        #expect(state.tab(id) != nil)
    }

    @Test func renamesAreNamedAndUndone() {
        var state = BrowserState.makeDefault()
        let a = state.openTab(url: url("a.com"))
        state.togglePin(tab: a)
        let rename = step(&state) { $0.renameTab(a, to: "Mine") }
        #expect(rename.name == "Rename Item")
        state.restoreSidebar(rename.before, other: rename.after)
        #expect(state.tab(a)?.customTitle == nil)

        let index = state.selectedSpaceIndex
        let folderStep = step(&state) { _ = $0.createFolder(name: "New Folder", inSpace: index) }
        #expect(folderStep.name == "New Folder")
        let folder = SidebarUndo.folders(in: state).first { $0.value == "New Folder" }!.key
        let renameFolder = step(&state) { $0.renameFolder(folder, to: "Work") }
        #expect(renameFolder.name == "Rename Item")
        state.restoreSidebar(renameFolder.before, other: renameFolder.after)
        #expect(SidebarUndo.folders(in: state)[folder] == "New Folder")
        state.restoreSidebar(folderStep.before, other: folderStep.after)
        #expect(SidebarUndo.folders(in: state)[folder] == nil)
    }

    @Test func deletingAFolderUndoesWithItsTabs() {
        var state = BrowserState.makeDefault()
        let index = state.selectedSpaceIndex
        let a = state.openTab(url: url("a.com"))
        let folder = state.createFolder(name: "Work", inSpace: index)
        let filed = state.moveTab(a, toFolder: folder)
        #expect(filed)
        let pinned = state.selectedSpace.pinnedItems
        let s = step(&state) { _ = $0.deleteFolder(folder) }
        #expect(s.name == "Delete Folder")
        state.restoreSidebar(s.before, other: s.after)
        #expect(state.selectedSpace.pinnedItems.map(\.id) == pinned.map(\.id))
        #expect(state.selectedSpace.pinned.contains { $0.id == a })
        #expect(!state.archived.contains { $0.tab.id == a })
    }

    @Test func folderOpenOrClosedIsNotAStepAndSurvivesUndo() {
        var state = BrowserState.makeDefault()
        let index = state.selectedSpaceIndex
        let folder = state.createFolder(name: "Work", inSpace: index)
        let toggle = step(&state) { $0.setFolderExpanded(folder, false) }
        #expect(toggle.name == nil)
        let a = state.openTab(url: url("a.com"))
        let s = step(&state) { _ = $0.moveTab(a, toFolder: folder) }
        #expect(s.name == "Move Item")
        state.setFolderExpanded(folder, true)
        state.restoreSidebar(s.before, other: s.after)
        let restored = state.selectedSpace.pinnedItems.compactMap { item -> TabFolder? in
            if case .folder(let f) = item { return f } else { return nil }
        }.first { $0.id == folder }
        #expect(restored?.isExpanded == true)
        #expect(restored?.items.isEmpty == true)
        #expect(state.location(of: a)?.section == .unpinned)
    }

    @Test func movingBetweenSpacesAndReordering() {
        var state = BrowserState.makeDefault()
        let home = state.selectedSpaceID
        let other = state.addSpace(name: "Other", icon: "", theme: Theme.presets[1])
        state.selectSpace(home)
        let a = state.openTab(url: url("a.com"))
        let b = state.openTab(url: url("b.com"))
        let reorder = step(&state) { $0.moveTabs(inSpace: $0.selectedSpaceID, pinned: false, fromOffsets: IndexSet(integer: 0), toOffset: 2) }
        #expect(reorder.name == "Move Item")
        let move = step(&state) { state in
            let s = state.selectedSpaceIndex
            let tab = state.spaces[s].tabs.first { $0.id == a }!
            state.spaces[s].tabs.removeAll { $0.id == a }
            state.spaces[state.spaceIndex(other)!].tabs.insert(tab, at: 0)
        }
        #expect(move.name == "Move Item")
        state.restoreSidebar(move.before, other: move.after)
        #expect(state.location(of: a)?.space == state.selectedSpaceIndex)
        #expect(state.spaces[state.spaceIndex(other)!].tabs.isEmpty)
        state.restoreSidebar(reorder.before, other: reorder.after)
        #expect(state.selectedSpace.tabs.prefix(2).map(\.id) == [b, a])
    }

    @Test func selectionAndPageUpdatesAreNotSteps() {
        var state = BrowserState.makeDefault()
        let a = state.openTab(url: url("a.com"))
        _ = state.openTab(url: url("b.com"))
        let select = step(&state) { $0.select(tab: a) }
        #expect(select.name == nil)
        let retitle = step(&state) { $0.update(tab: a) { $0.title = "A" } }
        #expect(retitle.name == nil)
    }

    @Test func spacesAreStepsLikeArcs() {
        var state = BrowserState.makeDefault()
        let home = state.selectedSpaceID
        let add = step(&state) { _ = $0.addSpace(name: "New", icon: "", theme: Theme.presets[2]) }
        #expect(add.name == "New Space")
        let new = state.selectedSpaceID
        state.restoreSidebar(add.before, other: add.after)
        #expect(state.spaceIndex(new) == nil)
        #expect(state.selectedSpaceID == home)
        state.restoreSidebar(add.after, other: add.before)
        #expect(state.spaceIndex(new) != nil)

        // Deleting a space with tabs, then undoing, brings it back whole, in place, with its tabs.
        state.selectSpace(new)
        let tab = state.openTab(url: url("a.com"))
        state.selectSpace(home)
        let order = state.spaces.map(\.id)
        let delete = step(&state) { $0.deleteSpace(new) }
        #expect(delete.name == "Delete Space")
        state.restoreSidebar(delete.before, other: delete.after)
        #expect(state.spaces.map(\.id) == order)
        #expect(state.spaces[state.spaceIndex(new)!].name == "New")
        #expect(state.location(of: tab)?.space == state.spaceIndex(new))

        let move = step(&state) { $0.moveSpace(new, to: 0) }
        #expect(move.name == "Move Space")
        state.restoreSidebar(move.before, other: move.after)
        #expect(state.spaces.map(\.id) == order)

        let rename = step(&state) { $0.renameSpace(new, to: "Work") }
        #expect(rename.name == "Customize Space")
        state.restoreSidebar(rename.before, other: rename.after)
        #expect(state.spaces[state.spaceIndex(new)!].name == "New")
    }

    @Test func favorites() {
        var state = BrowserState.makeDefault()
        let a = state.openTab(url: url("a.com"))
        let s = step(&state) { $0.toggleFavorite(tab: a) }
        #expect(s.name == "Move Item")
        state.restoreSidebar(s.before, other: s.after)
        #expect(state.location(of: a)?.section == .unpinned)
        #expect(state.favorites.isEmpty)
    }
}
