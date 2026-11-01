import Foundation
import Testing
@testable import KiteCore

@Suite struct FolderTests {
    private func stateWithFolder() throws -> (BrowserState, UUID, UUID, [UUID]) {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let space = state.spaces[0].id
        let folder = state.createFolder(name: "Reading", inSpace: 0)
        let inner = state.createFolder(name: "Inner", inSpace: 0)
        let a = state.openTab(url: URL(string: "https://a.example"), in: space, select: true)
        let b = state.openTab(url: URL(string: "https://b.example"), in: space, select: false)
        #expect(state.moveTab(a, toFolder: folder) && state.moveTab(b, toFolder: inner))
        // Nest Inner inside Reading.
        let moved = try #require(state.spaces[0].pinnedItems.removeFolder(inner))
        state.spaces[0].pinnedItems.updateFolder(folder) { $0.items.append(.folder(moved)) }
        return (state, space, folder, [a, b])
    }

    @Test func deletingAFolderArchivesItsTabsAndNestedFolders() throws {
        var (state, space, folder, tabs) = try stateWithFolder()
        let kept = state.openTab(url: URL(string: "https://kept.example"), in: space, select: false)
        state.spaces[0].selectedTabID = tabs[0]
        #expect(state.deleteFolder(folder).map(\.id) == tabs)
        #expect(state.folders(inSpace: 0).isEmpty)
        #expect(tabs.allSatisfy { state.tab($0) == nil })
        #expect(state.archived.map(\.tab.id).suffix(2) == tabs)
        #expect(state.archived.allSatisfy { $0.spaceID == space })
        #expect(state.spaces[0].selectedTabID == kept)
        #expect(state.deleteFolder(folder).isEmpty)
    }

    @Test func deletingAnEmptyFolderArchivesNothing() {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let folder = state.createFolder(name: "Empty", inSpace: 0)
        #expect(state.deleteFolder(folder).isEmpty)
        #expect(state.folders(inSpace: 0).isEmpty && state.archived.isEmpty)
    }

    @Test func renamingAFolderIgnoresBlankNames() throws {
        var (state, _, folder, _) = try stateWithFolder()
        state.renameFolder(folder, to: "  Work  ")
        #expect(state.folder(matching: folder.uuidString)?.folder.name == "Work")
        state.renameFolder(folder, to: "   ")
        #expect(state.folder(matching: folder.uuidString)?.folder.name == "Work")
    }

    @Test func aTaskClosingItsLastTabTakesTheEmptyFolder() {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let space = state.spaces[0].id
        let folder = state.createFolder(name: "Task", inSpace: 0)
        let a = state.openTab(url: URL(string: "https://a.example"), in: space, select: false)
        let b = state.openTab(url: URL(string: "https://b.example"), in: space, select: false)
        #expect(state.moveTab(a, toFolder: folder) && state.moveTab(b, toFolder: folder))
        #expect(state.removePinnedTab(a, droppingEmptyFolder: true))
        #expect(state.folder(matching: folder.uuidString) != nil)
        #expect(state.removePinnedTab(b, droppingEmptyFolder: true))
        #expect(state.folder(matching: folder.uuidString) == nil)
    }

    @Test func plainPinnedTabRemovalKeepsTheFolder() {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let space = state.spaces[0].id
        let folder = state.createFolder(name: "Mine", inSpace: 0)
        let a = state.openTab(url: URL(string: "https://a.example"), in: space, select: false)
        #expect(state.moveTab(a, toFolder: folder))
        #expect(state.removePinnedTab(a))
        #expect(state.folder(matching: folder.uuidString) != nil)
    }
}
