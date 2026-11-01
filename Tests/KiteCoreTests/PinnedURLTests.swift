import Foundation
import Testing
@testable import KiteCore

@Suite struct PinnedURLTests {
    private let home = URL(string: "https://mail.example.com/inbox")!
    private let away = URL(string: "https://mail.example.com/message/42")!

    private func pinnedState() -> (BrowserState, UUID) {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let id = state.openTab(url: home)
        state.togglePin(tab: id)
        return (state, id)
    }

    @Test func pinningRemembersThePageAndUnpinningForgetsIt() {
        var (state, id) = pinnedState()
        #expect(state.tab(id)?.pinnedURL == home)
        state.update(tab: id) { $0.url = away }
        #expect(state.tab(id)?.pinnedURL == home)
        state.togglePin(tab: id)
        #expect(state.tab(id)?.pinnedURL == nil)
        // Pinning again pins the page it's on now.
        state.togglePin(tab: id)
        #expect(state.tab(id)?.pinnedURL == away)
    }

    @Test func favoritesKeepTheirPinnedURL() {
        var (state, id) = pinnedState()
        state.toggleFavorite(tab: id)
        #expect(state.favorites.first?.pinnedURL == home)
        state.toggleFavorite(tab: id)
        #expect(state.tab(id)?.pinnedURL == nil)
    }

    @Test func resetGoesBackToThePinnedPage() {
        var (state, id) = pinnedState()
        #expect(!state.canReset(tab: id))
        let none = state.resetTab(id)
        #expect(none == nil)
        state.update(tab: id) { $0.url = away }
        #expect(state.canReset(tab: id))
        let reset = state.resetTab(id)
        #expect(reset == home)
        #expect(state.tab(id)?.url == home)
        #expect(!state.canReset(tab: id))
    }

    @Test func redirectsAndAnchorsDontCountAsLeaving() {
        var (state, id) = pinnedState()
        for url in ["http://www.mail.example.com/inbox/", "https://mail.example.com/inbox#unread", "HTTPS://Mail.Example.com/inbox"] {
            state.update(tab: id) { $0.url = URL(string: url) }
            #expect(!state.canReset(tab: id), "\(url)")
        }
        state.update(tab: id) { $0.url = URL(string: "https://mail.example.com/inbox?q=x") }
        #expect(state.canReset(tab: id))
    }

    @Test func unpinnedTabsCantReset() {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let id = state.openTab(url: home)
        state.update(tab: id) { $0.url = away }
        #expect(!state.canReset(tab: id))
        let none = state.resetTab(id)
        #expect(none == nil)
    }

    @Test func resetAllTabsResetsPinnedTabsInTheCurrentSpaceOnly() {
        var (state, id) = pinnedState()
        let folder = state.createFolder(name: "F", inSpace: 0)
        let inFolder = state.openTab(url: URL(string: "https://docs.example")!)
        state.togglePin(tab: inFolder)
        _ = state.moveTab(inFolder, toFolder: folder)
        let unpinned = state.openTab(url: home)
        let other = state.addSpace(name: "Other", icon: "x", theme: Theme.presets[1])
        let elsewhere = state.openTab(url: home, in: other)
        state.togglePin(tab: elsewhere)
        for tab in [id, inFolder, unpinned, elsewhere] { state.update(tab: tab) { $0.url = away } }
        state.selectSpace(state.spaces[0].id)

        let reset = state.resetPinnedTabs()
        #expect(Set(reset.map(\.id)) == [id, inFolder])
        #expect(state.tab(inFolder)?.url == URL(string: "https://docs.example"))
        #expect(state.tab(unpinned)?.url == away)
        #expect(state.tab(elsewhere)?.url == away)
    }

    @Test func separateOpensTheAwayPageAsANewTab() throws {
        var (state, id) = pinnedState()
        state.update(tab: id) { $0.url = away }
        let separated = state.separateFromPinnedTab(id)
        let new = try #require(separated)
        #expect(state.tab(id)?.url == home)
        #expect(state.tab(new)?.url == away)
        #expect(state.location(of: new)?.section == .unpinned)
        #expect(state.selectedSpace.selectedTabID == new)
    }

    @Test func oldSessionsAdoptTheCurrentPage() throws {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        state.spaces[0].pinnedItems = [.tab(BrowserTab(url: home))]
        let data = try JSONEncoder().encode(state)
        #expect(!String(decoding: data, as: UTF8.self).contains("pinnedURL"))
        let decoded = try JSONDecoder().decode(BrowserState.self, from: data)
        #expect(decoded.spaces[0].pinned.first?.pinnedURL == home)
    }

    @Test func revealOpensEnclosingFoldersAndNamesTheRow() throws {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let outer = state.createFolder(name: "Outer", inSpace: 0)
        let inner = state.createFolder(name: "Inner", inSpace: 0)
        let id = state.openTab(url: home)
        _ = state.moveTab(id, toFolder: inner)
        let taken = state.spaces[0].pinnedItems.removeFolder(inner)
        let removed = try #require(taken)
        state.spaces[0].pinnedItems.updateFolder(outer) { $0.items.append(.folder(removed)) }
        state.setFolderExpanded(outer, false)
        state.setFolderExpanded(inner, false)

        let row = state.revealTab(id)
        #expect(row == outer)
        #expect(state.folders(inSpace: 0).allSatisfy { $0.isExpanded })

        let loose = state.openTab(url: away)
        let looseRow = state.revealTab(loose)
        #expect(looseRow == loose)
    }

    @Test func editPinnedURLTakesAURLButNotASearch() {
        var (state, id) = pinnedState()
        #expect(state.hasPinnedURL(tab: id))
        let r1 = state.editPinnedURL(id, to: "not a url")
        #expect(!r1)
        let r2 = state.editPinnedURL(id, to: "  ")
        #expect(!r2)
        #expect(state.tab(id)?.pinnedURL == home)
        let r3 = state.editPinnedURL(id, to: " calendar.example.com/week ")
        #expect(r3)
        #expect(state.tab(id)?.pinnedURL == URL(string: "https://calendar.example.com/week"))
        // The page stays where it is, now away from its pinned URL.
        #expect(state.tab(id)?.url == home)
        #expect(state.canReset(tab: id))
        let r4 = state.editPinnedURL(id, to: "https://mail.example.com/inbox")
        #expect(r4)
        #expect(!state.canReset(tab: id))
    }

    @Test func replacePinnedURLWithCurrentPinsThePageItsOn() {
        var (state, id) = pinnedState()
        state.update(tab: id) { $0.url = away }
        let r5 = state.replacePinnedURLWithCurrent(id)
        #expect(r5)
        #expect(state.tab(id)?.pinnedURL == away)
        #expect(!state.canReset(tab: id))
    }

    @Test func favoritesCanEditAndReplaceButUnpinnedTabsCant() {
        var (state, id) = pinnedState()
        state.toggleFavorite(tab: id)
        let fav = state.favorites[0].id
        let r6 = state.editPinnedURL(fav, to: "example.org")
        #expect(r6)
        #expect(state.favorites[0].pinnedURL == URL(string: "https://example.org"))
        let r7 = state.replacePinnedURLWithCurrent(fav)
        #expect(r7)
        #expect(state.favorites[0].pinnedURL == home)

        let loose = state.openTab(url: away)
        #expect(!state.hasPinnedURL(tab: loose))
        let r8 = state.editPinnedURL(loose, to: "example.org")
        #expect(!r8)
        let r9 = state.replacePinnedURLWithCurrent(loose)
        #expect(!r9)
        #expect(state.tab(loose)?.pinnedURL == nil)
    }
}
