import Foundation
import Testing
@testable import KiteCore

/// Where a tab a page opened (a link to a new tab, a popup) goes: `openTab(url:openedBy:)`.
@Suite struct OpenedTabPlacementTests {
    private let ups = URL(string: "https://developer.ups.com/apps/add-app/shipper-account")
    private let addAccount = URL(string: "https://wwwapps.ups.com/doapp/AddExistingAccount?loc=en_US")

    /// Komado with a tab of the user's and Claude › `session` (or just Claude) holding Claude's UPS tab,
    /// and Personal in front.
    private func claudeTab(session: String? = nil) throws -> (state: BrowserState, opener: UUID, mine: UUID, folder: UUID) {
        var state = BrowserState(spaces: [Space(name: "Komado", icon: "🈳", theme: Theme.presets[0]),
                                          Space(name: "Personal", icon: "🏠", theme: Theme.presets[1])])
        let komado = state.spaces[0].id
        let mine = state.openTab(url: URL(string: "https://komado.com"), in: komado, select: false)
        let made = session.map { state.claudeSessionFolder(named: $0, inSpace: komado) } ?? state.claudeFolder(inSpace: komado)
        let folder = try #require(made)
        let opener = state.openTab(url: ups, in: komado, select: false)
        let moved = state.moveTab(opener, toFolder: folder)
        #expect(moved)
        state.selectSpace(state.spaces[1].id)
        return (state, opener, mine, folder)
    }

    private func items(of folder: UUID, in state: BrowserState) -> [UUID] {
        state.folders(inSpace: 0).first { $0.id == folder }?.items.map(\.id) ?? []
    }

    @Test func aPopupFromAClaudeTabOpensInTheClaudeFolderAfterIt() throws {
        var (state, opener, mine, folder) = try claudeTab()
        let popup = state.openTab(url: addAccount, openedBy: opener)
        #expect(items(of: folder, in: state) == [opener, popup])
        #expect(state.location(of: popup)?.section == .pinned)
        #expect(state.isInEphemeralFolder(popup))
        // Not a loose tab next to the user's.
        #expect(state.spaces[0].tabs.map(\.id) == [mine])
        // A foreground tab comes to the front, in its opener's space.
        #expect(state.selectedTab?.id == popup && state.selectedSpaceID == state.spaces[0].id)
    }

    @Test func aTabFromASessionsTabStaysInThatSessionsFolder() throws {
        var (state, opener, _, session) = try claudeTab(session: "Carrier API keys")
        let first = state.openTab(url: addAccount, openedBy: opener, select: false)
        let second = state.openTab(url: addAccount, openedBy: opener, select: false)
        // Each goes right after its opener, inside Claude › Carrier API keys.
        #expect(items(of: session, in: state) == [opener, second, first])
        let claude = try #require(state.folders(inSpace: 0).first)
        #expect(claude.name == "Claude" && claude.items.map(\.id) == [session])
        // A background tab leaves the front tab and space alone.
        #expect(state.selectedSpaceID == state.spaces[1].id && state.spaces[0].selectedTabID == nil)
    }

    @Test func aTabFromASplitInAClaudeFolderGoesAfterTheSplit() throws {
        var (state, opener, _, folder) = try claudeTab()
        state.select(tab: opener)
        guard case .added(let pane) = state.addSplitPane() else { Issue.record("no split"); return }
        let child = state.openTab(url: addAccount, openedBy: opener, select: false)
        #expect(items(of: folder, in: state) == [opener, pane, child])
        #expect(state.split(containing: child)?.split == nil)
    }

    @Test func tabsFromTheUsersOwnTabsOpenAtTheTopAsInArc() throws {
        var (state, _, mine, _) = try claudeTab()
        let komado = state.spaces[0].id
        let pinned = state.openTab(url: URL(string: "https://github.com"), in: komado, select: false)
        state.togglePin(tab: pinned)
        let work = state.createFolder(name: "Work", inSpace: 0)
        let filed = state.openTab(url: URL(string: "https://linear.app"), in: komado, select: false)
        _ = state.moveTab(filed, toFolder: work)
        state.selectSpace(komado)
        for opener in [mine, pinned, filed] {
            let child = state.openTab(url: addAccount, openedBy: opener, select: false)
            #expect(state.location(of: child) == TabLocation(space: 0, section: .unpinned, index: 0))
            #expect(state.tab(child)?.openedByPage == nil)
        }
        #expect(items(of: work, in: state) == [filed])
    }

    @Test func closingATabAPageOpenedRemovesIt() throws {
        var (state, opener, _, session) = try claudeTab(session: "Carrier API keys")
        let popup = state.openTab(url: addAccount, openedBy: opener)
        #expect(state.closesForGood(tab: popup) && state.showsCloseButton(tab: popup))
        // Claude's own tab still only unloads.
        #expect(!state.closesForGood(tab: opener))
        // A popup that calls window.close(), or the user's ⌘W, takes it out of the folder and into the archive.
        #expect(state.close(tab: popup) == .removed)
        #expect(state.tab(popup) == nil && items(of: session, in: state) == [opener])
        #expect(state.archived.last?.tab.id == popup && state.archived.last?.tab.openedByPage == nil)
        // Reopened, it's an ordinary unpinned tab.
        let reopened = state.reopenLastClosed()
        #expect(reopened == popup && state.location(of: popup)?.section == .unpinned)
    }

    @Test func aTabMovedOutOfTheClaudeFolderIsTheUsersAgain() throws {
        var (state, opener, _, _) = try claudeTab()
        let popup = state.openTab(url: addAccount, openedBy: opener, select: false)
        let work = state.createFolder(name: "Work", inSpace: 0)
        _ = state.moveTab(popup, toFolder: work)
        // In the user's own folder it behaves like their other pinned tabs: closing unloads it.
        #expect(!state.closesForGood(tab: popup))
        #expect(state.close(tab: popup) == .unloaded)
    }

    @Test func savedSessionsWithoutTheFlagStillDecode() throws {
        var (state, opener, _, _) = try claudeTab()
        let popup = state.openTab(url: addAccount, openedBy: opener, select: false)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.tab(popup)?.openedByPage == true)
        let old = try JSONDecoder().decode(BrowserTab.self, from: Data(#"{"id":"\#(UUID().uuidString)","title":"","lastActiveAt":0}"#.utf8))
        #expect(old.openedByPage == nil)
    }
}

/// What Claude's tools say about tabs an action opened (`OpenedTabs`, `AutomationReport.opened`).
@Suite struct OpenedTabsReportTests {
    private let wizard = UUID()
    private let page = URL(string: "https://wwwapps.ups.com/doapp/AddExistingAccount?loc=en_US")!

    @Test func remembersWhichTabOpenedWhichAndWhen() {
        var opened = OpenedTabs()
        let first = UUID(), second = UUID(), other = UUID()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        opened.record(child: first, opener: wizard, at: start)
        opened.record(child: other, opener: UUID(), at: start.addingTimeInterval(5))
        opened.record(child: second, opener: wizard, at: start.addingTimeInterval(10))
        #expect(opened.opener(of: second) == wizard && opened.opener(of: wizard) == nil)
        // An action's result names only what it opened.
        #expect(opened.opened(by: wizard, since: start.addingTimeInterval(1)) == [second])
        #expect(opened.opened(by: wizard, since: start) == [first, second])
        opened.retain(live: [wizard, second])
        #expect(opened.opened(by: wizard, since: start) == [second])
    }

    @Test func spotsTheSamePageOpenedAgain() {
        // UPS's Add App wizard: picking "Add an existing account" again opened the same popup again.
        var opened = OpenedTabs()
        let first = UUID(), second = UUID(), elsewhere = UUID()
        opened.record(child: first, opener: wizard, at: Date(timeIntervalSinceReferenceDate: 1))
        opened.record(child: elsewhere, opener: UUID(), at: Date(timeIntervalSinceReferenceDate: 2))
        opened.record(child: second, opener: wizard, at: Date(timeIntervalSinceReferenceDate: 3))
        let urls: [UUID: URL] = [
            // The site redirected the first to lower case; a fragment doesn't make another page.
            first: URL(string: "https://wwwapps.ups.com/doapp/addexistingaccount?loc=en_US")!,
            second: URL(string: "https://wwwapps.ups.com/doapp/AddExistingAccount?loc=en_US#top")!,
            elsewhere: page,
        ]
        #expect(opened.earlierCopy(of: second) { urls[$0] } == first)
        #expect(opened.earlierCopy(of: first) { urls[$0] } == nil)
        // Another tab's popup isn't a copy, and neither is another page.
        #expect(opened.earlierCopy(of: elsewhere) { urls[$0] } == nil)
        #expect(opened.earlierCopy(of: second) { $0 == second ? URL(string: "https://wwwapps.ups.com/doapp/next") : urls[$0] } == nil)
    }

    @Test func tellsClaudeWhereTheWorkWentAndWhatToTidy() throws {
        #expect(AutomationReport.opened([], by: wizard) == nil)
        let earlier = UUID(), popup = UUID()
        let text = try #require(AutomationReport.opened(
            [AutomationReport.OpenedTab(id: popup, title: "", url: page, isFront: true, copyOf: earlier)], by: wizard))
        #expect(text.contains("This opened a new tab (next to tab \(wizard.uuidString))"))
        #expect(text.contains("- tab \(popup.uuidString) [front]"))
        #expect(text.contains("pass tab \(popup.uuidString) to keep working in it"))
        #expect(text.contains("same page as tab \(earlier.uuidString)") && text.contains("tabs_close"))
        // The opener stays: the flow may come back to it.
        #expect(text.contains("Keep tab \(wizard.uuidString) open"))
        // Page titles and URLs are the page's words.
        #expect(text.contains("<\(UntrustedContent.tag)"))

        let list = AutomationReport.tabs([AutomationReport.Tab(id: popup, title: "Add", url: page, space: "Komado", section: "pinned",
                                                               isFront: true, openedBy: wizard)])
        #expect(list.contains("[Komado, front, pinned, opened by tab \(wizard.uuidString)]"))
        #expect(MCPServer.instructions.contains("When an action opens new tabs"))
    }
}

@Suite struct AutomaticSessionFolderTests {
    @Test func aSessionThatNamesNoneGetsTheSiteAndTime() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let at = Date(timeIntervalSince1970: 14 * 3600 + 5 * 60)
        #expect(BrowserState.automaticSessionFolderName(for: URL(string: "https://developer.ups.com/apps"), at: at, timeZone: utc)
            == "developer.ups.com · 14:05")
        #expect(BrowserState.automaticSessionFolderName(for: URL(string: "https://www.fedex.com/"), at: at, timeZone: utc) == "fedex.com · 14:05")
        // A blank tab.
        #expect(BrowserState.automaticSessionFolderName(for: nil, at: at, timeZone: utc) == "Claude · 14:05")
        // It's a session folder like any other: Claude › that name, and a popup from it stays in it.
        var state = BrowserState(spaces: [Space(name: "Komado", icon: "🈳", theme: Theme.presets[0])])
        let name = BrowserState.automaticSessionFolderName(for: URL(string: "https://developer.ups.com"), at: at, timeZone: utc)
        let made = state.claudeSessionFolder(named: name, inSpace: state.spaces[0].id)
        let folder = try #require(made)
        let tab = state.openTab(url: URL(string: "https://developer.ups.com"), select: false)
        _ = state.moveTab(tab, toFolder: folder)
        let popup = state.openTab(url: URL(string: "https://wwwapps.ups.com/doapp/AddExistingAccount"), openedBy: tab)
        #expect(state.folders(inSpace: 0).map(\.name) == ["Claude", "developer.ups.com · 14:05"])
        #expect(state.folders(inSpace: 0)[1].items.map(\.id) == [tab, popup])
    }
}
