import Foundation
import Testing
@testable import KiteCore

@Suite struct URLInputTests {
    @Test(arguments: [
        ("apple.com", "https://apple.com"),
        ("news.ycombinator.com/item?id=1", "https://news.ycombinator.com/item?id=1"),
        ("localhost:3000", "http://localhost:3000"),
        ("192.168.1.10:8080/admin", "http://192.168.1.10:8080/admin"),
        ("https://example.org/a b", "https://example.org/a%20b"),
        ("about:blank", "about:blank"),
    ])
    func resolvesURLs(input: String, expected: String) {
        #expect(URLInput.resolve(input, engine: .google)?.absoluteString == expected)
        #expect(URLInput.looksLikeURL(input))
    }

    @Test(arguments: ["swift concurrency", "what is 2+2", "kite", "file.txt please", "a.b"])
    func searchesEverythingElse(input: String) {
        let url = URLInput.resolve(input, engine: .duckDuckGo)
        #expect(url?.host() == "duckduckgo.com")
        #expect(!URLInput.looksLikeURL(input))
    }

    @Test func typedAppLinksAreURLs() {
        let appOpens = URLInput.appOpens
        URLInput.appOpens = { $0.scheme == "claude" || $0.scheme == "todo" }
        defer { URLInput.appOpens = appOpens }
        let link = "claude://claude.ai/magic-link?a=1#b"
        #expect(URLInput.resolve(link, engine: .google)?.absoluteString == link)
        #expect(URLInput.looksLikeURL(link))
        // Without "://", or with no app for it, it's still a search.
        #expect(URLInput.resolve("todo:milk", engine: .google)?.host() == "www.google.com")
        #expect(URLInput.resolve("nobody://x", engine: .google)?.host() == "www.google.com")
    }

    @Test func encodesQueryCharacters() {
        let url = SearchEngine.google.searchURL(for: "c++ & rust?")
        #expect(url.absoluteString == "https://www.google.com/search?q=c%2B%2B%20%26%20rust%3F")
    }

    @Test func emptyInputResolvesToNothing() {
        #expect(URLInput.resolve("   ", engine: .google) == nil)
    }
}

@Suite struct BrowserStateTests {
    private func makeState(tabs: Int) -> (BrowserState, [UUID]) {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        var ids: [UUID] = []
        for i in 0..<tabs {
            ids.append(state.openTab(url: URL(string: "https://site\(i).com")))
        }
        // openTab inserts at the top, so sidebar order is the reverse of creation.
        return (state, ids.reversed())
    }

    @Test func openTabSelectsAndGoesOnTop() {
        let (state, ids) = makeState(tabs: 3)
        #expect(state.selectedSpace.tabs.map(\.id) == ids)
        #expect(state.selectedTab?.id == ids[0])
    }

    @Test func closingSelectedTabSelectsTheNextOne() {
        var (state, ids) = makeState(tabs: 3)
        state.select(tab: ids[1])
        #expect(state.close(tab: ids[1]) == .removed)
        #expect(state.selectedTab?.id == ids[2])
        #expect(state.close(tab: ids[2]) == .removed)
        #expect(state.selectedTab?.id == ids[0])
        #expect(state.close(tab: ids[0]) == .removed)
        #expect(state.selectedTab == nil)
    }

    @Test func closingPinnedTabUnloadsIt() {
        var (state, ids) = makeState(tabs: 2)
        state.togglePin(tab: ids[0])
        state.select(tab: ids[0])
        #expect(state.close(tab: ids[0]) == .unloaded)
        #expect(state.selectedSpace.pinned.map(\.id) == [ids[0]])
        #expect(state.selectedTab?.id == ids[1])
    }

    @Test func reopenRestoresPosition() {
        var (state, ids) = makeState(tabs: 3)
        state.close(tab: ids[1])
        let reopened = state.reopenLastClosed()
        #expect(reopened == ids[1])
        #expect(state.selectedSpace.tabs.map(\.id) == ids)
        #expect(state.recentlyClosed.isEmpty)
    }

    @Test func pinAndUnpin() {
        var (state, ids) = makeState(tabs: 2)
        state.togglePin(tab: ids[1])
        #expect(state.selectedSpace.pinned.map(\.id) == [ids[1]])
        #expect(state.selectedSpace.tabs.map(\.id) == [ids[0]])
        state.togglePin(tab: ids[1])
        #expect(state.selectedSpace.pinned.isEmpty)
        #expect(state.selectedSpace.tabs.first?.id == ids[1])
    }

    @Test func moveTabsMatchesOnMoveSemantics() {
        var (state, ids) = makeState(tabs: 4)
        state.moveTabs(inSpace: state.selectedSpaceID, pinned: false, fromOffsets: [0], toOffset: 3)
        #expect(state.selectedSpace.tabs.map(\.id) == [ids[1], ids[2], ids[0], ids[3]])
    }

    @Test func tabNumbersAndCycling() {
        var (state, ids) = makeState(tabs: 4)
        state.selectTab(number: 2)
        #expect(state.selectedTab?.id == ids[1])
        state.selectTab(number: 9)
        #expect(state.selectedTab?.id == ids[3])
        state.selectAdjacentTab(offset: 1)
        #expect(state.selectedTab?.id == ids[0])
        state.selectAdjacentTab(offset: -1)
        #expect(state.selectedTab?.id == ids[3])
    }

    @Test func archivesOnlyStaleUnpinnedUnselectedTabs() {
        let old = Date(timeIntervalSince1970: 0)
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let stale = state.openTab(url: nil, select: false, now: old)
        let pinned = state.openTab(url: nil, select: false, now: old)
        state.togglePin(tab: pinned)
        let selected = state.openTab(url: nil, now: old)
        let fresh = state.openTab(url: nil, select: false)

        let archived = state.archiveStaleTabs(olderThan: 3600)
        #expect(archived.map(\.id) == [stale])
        #expect(state.allTabIDs == [pinned, selected, fresh])
        #expect(state.archived.map(\.tab.id) == [stale])
    }

    @Test func closingArchivesUntilReopened() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let tab = state.openTab(url: URL(string: "https://example.com"))
        state.close(tab: tab)
        #expect(state.archived.map(\.tab.id) == [tab])
        state.reopenLastClosed()
        #expect(state.archived.isEmpty)
    }

    @Test func archiveIntervalDefaultsToTwelveHoursAndPersists() throws {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        #expect(state.archiveAfter == .twelveHours)
        state.archiveAfter = .sevenDays
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.archiveAfter == .sevenDays)
        // Unwrapped first: comparing an Optional<Double> in #expect crashes the Windows 6.2 compiler.
        let thirtyDays = try #require(ArchiveInterval.thirtyDays.seconds)
        #expect(thirtyDays == 30 * 24 * 3600)
        #expect(ArchiveInterval.never.seconds == nil)
        // The first version's names still load.
        let old = try JSONDecoder().decode([ArchiveInterval].self, from: Data(#"["week", "day", "bogus"]"#.utf8))
        #expect(old == [.sevenDays, .twentyFourHours, .twelveHours])
    }

    @Test func toolbarIsOffByDefaultAndPersists() throws {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        #expect(!state.showsToolbar)
        state.showsToolbar = true
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.showsToolbar)
    }

    @Test func quitWarningIsOffByDefaultAndPersists() throws {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        #expect(!state.warnsBeforeQuitting)
        state.warnsBeforeQuitting = true
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.warnsBeforeQuitting)
    }

    @Test func quitWarningSavedBeforeItWasOffByDefaultIsDropped() throws {
        // Older sessions always saved `"warnsBeforeQuitting": true`.
        let state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json.removeValue(forKey: "asksBeforeQuitting")
        json["warnsBeforeQuitting"] = true
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.warnsBeforeQuitting)
    }

    @Test func spacesCycleAndSelectionFollowsTab() {
        var state = BrowserState.makeDefault(seedURL: nil)
        let work = state.spaces[1].id
        let tab = state.openTab(url: nil, in: work, select: false)
        state.selectSpace(at: 0)
        state.select(tab: tab)
        #expect(state.selectedSpaceID == work)
        state.selectAdjacentSpace(offset: 1)
        #expect(state.selectedSpaceIndex == 0)
    }
}

@Suite struct DarkPagesTests {
    @Test func modesAndPerSiteFlips() {
        var state = BrowserState.makeDefault(seedURL: nil)
        let docs = URL(string: "https://Docs.example.com/a")
        let other = URL(string: "https://other.example.com")

        // Default follows the OS.
        #expect(state.darkPages == .matchSystem)
        #expect(state.wantsDarkPage(for: docs, systemIsDark: true))
        #expect(!state.wantsDarkPage(for: docs, systemIsDark: false))

        // A per-site flip inverts the default for that site only.
        state.toggleDarkPage(for: docs)
        #expect(!state.wantsDarkPage(for: docs, systemIsDark: true))
        #expect(state.wantsDarkPage(for: docs, systemIsDark: false))
        #expect(state.wantsDarkPage(for: other, systemIsDark: true))

        state.darkPages = .off
        #expect(state.wantsDarkPage(for: docs, systemIsDark: true))
        #expect(!state.wantsDarkPage(for: other, systemIsDark: true))
    }

    @Test func decodesSessionsFromBeforeDarkPagesAndFolders() throws {
        var state = BrowserState.makeDefault()
        let tab = state.openTab(url: URL(string: "https://example.com"))
        state.togglePin(tab: tab)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json["darkPageHosts"] = nil
        json["darkPages"] = nil
        json["archived"] = nil
        // Old sessions stored pinned tabs as a flat array.
        var spaces = json["spaces"] as! [[String: Any]]
        let pinnedTabJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode([state.spaces[0].pinned[0]]))
        spaces[0]["pinned"] = pinnedTabJSON
        spaces[0]["pinnedItems"] = nil
        json["spaces"] = spaces

        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.spaces == state.spaces)
        #expect(decoded.darkPageHosts.isEmpty)
        #expect(decoded.darkPages == .matchSystem)
    }
}

@Suite struct PageAppearanceTests {
    @Test func defaultsToAutomaticAndSurvivesARelaunch() throws {
        var state = BrowserState.makeDefault(seedURL: nil)
        #expect(state.pageAppearance == .automatic)

        state.pageAppearance = .dark
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.pageAppearance == .dark)

        // Sessions saved before View › Appearance follow macOS.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json["pageAppearance"] = nil
        let old = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.pageAppearance == .automatic)
    }

    @Test func mapsArcsAppearanceNames() {
        #expect(PageAppearance(appearanceName: nil) == .automatic)
        #expect(PageAppearance(appearanceName: "NSAppearanceNameAqua") == .light)
        #expect(PageAppearance(appearanceName: "NSAppearanceNameDarkAqua") == .dark)
        #expect(PageAppearance(appearanceName: "NSAppearanceNameVibrantDark") == .automatic)
        #expect(PageAppearance.allCases.map { PageAppearance(appearanceName: $0.appearanceName) } == PageAppearance.allCases)
    }
}

@Suite struct FolderTests {
    @Test func tabsInsideFoldersBehaveLikePinnedTabs() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let inner = BrowserTab(url: URL(string: "https://inner.example"))
        let deep = BrowserTab(url: URL(string: "https://deep.example"))
        let folder = TabFolder(name: "Work", items: [.tab(inner), .folder(TabFolder(name: "Deep", items: [.tab(deep)]))])
        state.spaces[0].pinnedItems = [.folder(folder)]

        #expect(state.selectedSpace.pinned.map(\.id) == [inner.id, deep.id])
        state.select(tab: deep.id)
        #expect(state.selectedTab?.id == deep.id)

        state.update(tab: deep.id) { $0.title = "Deep page" }
        #expect(state.tab(deep.id)?.title == "Deep page")

        #expect(state.close(tab: deep.id) == .unloaded)
        #expect(state.selectedTab?.id == inner.id)

        state.togglePin(tab: deep.id)
        #expect(state.selectedSpace.tabs.map(\.id) == [deep.id])
        #expect(state.selectedSpace.pinned.map(\.id) == [inner.id])

        state.setFolderExpanded(folder.id, false)
        guard case .folder(let collapsed) = state.selectedSpace.pinnedItems[0] else {
            Issue.record("folder lost")
            return
        }
        #expect(!collapsed.isExpanded)
    }
}

@Suite struct FavoritesTests {
    @Test func favoritesAreSharedAndOpenInTheCurrentSpace() {
        var state = BrowserState.makeDefault(seedURL: nil)
        let mail = state.openTab(url: URL(string: "https://mail.example"))
        state.toggleFavorite(tab: mail)
        #expect(state.favorites.map(\.id) == [mail])
        #expect(state.selectedSpace.tabs.isEmpty)

        // Selecting a favorite from another space keeps you in that space.
        state.selectSpace(at: 1)
        state.select(tab: mail)
        #expect(state.selectedSpaceIndex == 1)
        #expect(state.selectedTab?.id == mail)
        #expect(state.allTabIDs.contains(mail))

        // Closing a favorite unloads it, like a pinned tab.
        #expect(state.close(tab: mail) == .unloaded)
        #expect(state.favorites.count == 1)
        #expect(state.selectedTab == nil)

        state.toggleFavorite(tab: mail)
        #expect(state.favorites.isEmpty)
        #expect(state.spaces[1].tabs.map(\.id) == [mail])
    }
}

@Suite struct TabSearchTests {
    @Test func ranksTitlePrefixAboveURLMatches() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let docs = state.openTab(url: URL(string: "https://swift.org/docs"))
        state.update(tab: docs) { $0.title = "Documentation" }
        let gh = state.openTab(url: URL(string: "https://github.com/swiftlang/swift"))
        state.update(tab: gh) { $0.title = "swiftlang/swift" }

        let results = TabSearch.rank("swift", in: state)
        #expect(results.map(\.tab.id) == [gh, docs])
        #expect(TabSearch.rank("doc", in: state).first?.tab.id == docs)
        #expect(TabSearch.rank("zzz", in: state).isEmpty)
    }

    @Test func findsAFavoriteByItsPageTitle() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let mail = state.openTab(url: URL(string: "https://mail.google.com/mail/u/0/#inbox"))
        state.update(tab: mail) { $0.title = "Inbox (3) - someone@example.com - Gmail" }
        state.toggleFavorite(tab: mail)
        #expect(TabSearch.rank("gmail", in: state).map(\.tab.id) == [mail])
        #expect(TabSearch.rank("inbox", in: state).map(\.tab.id) == [mail])
    }

    @Test func findsTabsBySiteNameWhenTheTitleDoesntSayIt() {
        // A Workspace inbox's title says "Komado Lab Mail", not Gmail: "gmail" still finds it by its host.
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let mail = state.openTab(url: URL(string: "https://mail.google.com/mail/u/0/#inbox"))
        state.update(tab: mail) { $0.title = "Inbox (3) - gabe@komadolab.com - Komado Lab Mail" }
        state.toggleFavorite(tab: mail)
        let tube = state.openTab(url: URL(string: "https://music.youtube.com/"))
        state.update(tab: tube) { $0.title = "Home" }
        state.togglePin(tab: tube)
        let hub = state.openTab(url: URL(string: "https://github.com/gabekus/kite"))
        state.update(tab: hub) { $0.title = "kite" }
        let cal = state.openTab(url: URL(string: "https://calendar.google.com/calendar/r"))
        state.update(tab: cal) { $0.title = "Calendar" }

        #expect(TabSearch.rank("gmail", in: state).map(\.tab.id) == [mail])
        #expect(TabSearch.rank("Gmail ", in: state).first?.strength == TabSearch.hostPrefix)
        #expect(TabSearch.rank("gm", in: state).map(\.tab.id) == [mail])
        #expect(TabSearch.rank("gmailx", in: state).isEmpty)
        #expect(TabSearch.rank("yt", in: state).map(\.tab.id) == [tube])  // a pinned tab, on a subdomain
        #expect(TabSearch.rank("gh", in: state).map(\.tab.id) == [hub])  // an open tab
        #expect(TabSearch.rank("gcal", in: state).map(\.tab.id) == [cal])
        // One letter is too little to be a site's name.
        #expect(!TabSearch.startsSiteName("g", of: "mail.google.com"))
    }

    @Test func switchTargetsLeaveOutTheTabYoureOnAndStillGiveFive() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let ids = (0..<7).map { i in
            let id = state.openTab(url: URL(string: "https://example.com/\(i)"))
            state.update(tab: id) { $0.title = "Notes \(i)" }
            return id
        }
        state.select(tab: ids[6])
        let targets = TabSearch.switchTargets("notes", in: state).map(\.tab.id)
        #expect(targets.count == 5)
        #expect(!targets.contains(ids[6]))
        #expect(TabSearch.switchTargets("zzz", in: state).isEmpty)
    }
}

/// Arc 1.171, 3 Nov 2026: a favorite with nothing learned for it.
@Suite struct CommandBarOrderTests {
    func order(leader: String?, tabs: [String], commands: [String] = []) -> [String] {
        CommandBarOrder.arrange(leader: leader, strongCommands: commands, search: "search", tabs: tabs,
                                engine: ["e1", "e2"], history: ["h"], weakCommands: ["weak"])
    }

    func gmail(favorite: Bool = true) -> (BrowserState, UUID) {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let mail = state.openTab(url: URL(string: "https://mail.google.com/mail/u/0/#inbox"))
        state.update(tab: mail) { $0.title = "Inbox (3) - someone@example.com - Gmail" }
        if favorite { state.toggleFavorite(tab: mail) }
        let other = state.openTab(url: URL(string: "https://example.com"))
        state.select(tab: other)
        return (state, mail)
    }

    func leader(_ query: String, _ state: BrowserState) -> UUID? {
        CommandBarOrder.leader(query, shown: query, in: state, typedMatches: TabSearch.switchTargets(query, in: state),
                               looksLikeURL: URLInput.looksLikeURL(query))?.id
    }

    @Test func aTabMatchSitsUnderTheTypedSearchAboveSuggestions() {
        // Arc showed this for 4, 5, 6, 8 and 11 letters of a favorite's name: search row, then "Switch to Tab".
        let (state, mail) = gmail()
        for query in ["inbo", "inbox", "inbox ", "inbox (3", "inbox (3) -"] {
            #expect(TabSearch.switchTargets(query, in: state).first?.tab.id == mail)
            #expect(leader(query, state) == nil)
        }
        #expect(order(leader: nil, tabs: ["fav", "tab"]) == ["search", "fav", "tab", "e1", "e2", "h", "weak"])
    }

    @Test func aShortQueryPutsAStrongTabMatchFirst() {
        // Arc showed this for 1, 2 and 3 letters of a favorite's name: "Switch to Tab" first and selected.
        let (state, mail) = gmail()
        for query in ["i", "in", "inb", " in ", "gm"] {
            #expect(leader(query, state) == mail)
        }
        #expect(order(leader: "fav", tabs: ["tab"]) == ["fav", "search", "tab", "e1", "e2", "h", "weak"])
    }

    @Test func typingAFavoritesAddressPutsItFirstAtAnyLength() {
        // Arc showed this for 2 to 10 letters of an 11-letter host; the whole host opened it as a URL instead.
        let (state, mail) = gmail()
        for query in ["mail", "mail.", "mail.goo", "mail.google.co"] {
            #expect(leader(query, state) == mail)
        }
        #expect(leader("mail.google.com", state) == nil)
        #expect(leader("mail.google.com/", state) == nil)
        // The favorite you're on doesn't lead.
        var front = state
        front.select(tab: mail)
        #expect(leader("mail.goo", front) == nil)
        // Only favorites: an open tab's address past three letters stays under the search (not observed in Arc).
        let (tabs, _) = gmail(favorite: false)
        #expect(leader("mail.goo", tabs) == nil)
    }

    @Test func aRedirectedFavoriteLeadsByItsPinnedAddress() {
        let (base, mail) = gmail()
        var state = base
        state.update(tab: mail) {
            $0.url = URL(string: "https://accounts.google.com/v3/signin/identifier")
            $0.title = "Gmail"
        }
        #expect(state.tab(mail)?.pinnedURL?.host() == "mail.google.com")
        #expect(leader("mail.goo", state) == mail)
    }

    @Test func theFavoriteLeadsEvenBehindStrongerMatches() {
        // Six tabs whose titles start with "mail" outrank the favorite's host match; it still leads.
        let (base, mail) = gmail()
        var state = base
        for i in 0..<6 {
            let id = state.openTab(url: URL(string: "https://example.com/\(i)"))
            state.update(tab: id) { $0.title = "Mailing list \(i)" }
        }
        #expect(TabSearch.switchTargets("mail", in: state).allSatisfy { $0.tab.id != mail })
        #expect(leader("mail", state) == mail)
    }

    @Test func aURLLookingQueryLeadsOnlyWithAFavoritesAddress() {
        // A Site Search completion ("gi" + "thub.com") is URL-like: only a favorite on that host goes above Open.
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let hub = state.openTab(url: URL(string: "https://github.com/gabekus"))
        state.update(tab: hub) { $0.title = "gabekus" }
        state.select(tab: state.openTab(url: URL(string: "https://example.com")))
        func lead(_ url: Bool) -> UUID? {
            CommandBarOrder.leader("gi", shown: url ? "github.com" : "gi", in: state,
                                   typedMatches: TabSearch.switchTargets("gi", in: state), looksLikeURL: url)?.id
        }
        #expect(lead(true) == nil)
        #expect(lead(false) == hub)
        state.toggleFavorite(tab: hub)
        #expect(lead(true) == hub)
        #expect(CommandBarOrder.arrangeURL(leader: "fav", open: "open", tabs: ["tab"], history: ["h"], search: "search")
            == ["fav", "open", "tab", "h", "search"])
        #expect(CommandBarOrder.arrangeURL(leader: nil, open: "open", tabs: [], history: [], search: "search")
            == ["open", "search"])
    }

    @Test func aNonURLCompletionKeepsTheShortRuleOut() {
        // A Site Search keyword "wiki" completing "w": the best tab for "w" would disagree with the field.
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let w = state.openTab(url: URL(string: "https://example.com"))
        state.update(tab: w) { $0.title = "Weather" }
        state.select(tab: state.openTab(url: URL(string: "https://example.org")))
        let matches = TabSearch.switchTargets("w", in: state)
        #expect(CommandBarOrder.leader("w", shown: "w", in: state, typedMatches: matches, looksLikeURL: false)?.id == w)
        #expect(CommandBarOrder.leader("w", shown: "wiki", in: state, typedMatches: matches, looksLikeURL: false) == nil)
    }

    @Test func ofTwoFavoritesOnTheTypedAddressTheOneUsedLastLeads() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let mail = state.openTab(url: URL(string: "https://mail.google.com"))
        let maps = state.openTab(url: URL(string: "https://maps.google.com"))
        state.toggleFavorite(tab: mail)
        state.toggleFavorite(tab: maps)
        state.select(tab: maps, now: Date(timeIntervalSince1970: 100))
        state.select(tab: mail, now: Date(timeIntervalSince1970: 200))
        state.select(tab: state.openTab(url: URL(string: "https://example.com")), now: Date(timeIntervalSince1970: 300))
        #expect(leader("ma", state) == mail)
        state.select(tab: maps, now: Date(timeIntervalSince1970: 400))
        state.select(tab: state.openTab(url: URL(string: "https://example.org")), now: Date(timeIntervalSince1970: 500))
        #expect(leader("ma", state) == maps)
        // A whole host gets the Open row even when the favorite's other host only starts with it.
        state.update(tab: mail) { $0.url = URL(string: "https://mail.google.com.au") }
        #expect(leader("mail.google.com", state) == nil)
        // "www." is left off the host, not matched.
        #expect(leader("www.ma", state) == nil)
    }

    @Test func aCompletionForAnotherSiteKeepsTheFavoriteOut() {
        // "m" completed to "music.apple.com" in the field: the Gmail favorite would disagree with it.
        let (state, mail) = gmail()
        func lead(_ shown: String) -> UUID? {
            CommandBarOrder.leader("m", shown: shown, in: state, typedMatches: TabSearch.switchTargets("m", in: state),
                                   looksLikeURL: URLInput.looksLikeURL(shown))?.id
        }
        #expect(lead("music.apple.com") == nil)
        #expect(lead("mail.google.com") == mail)
        #expect(lead("m") == mail)
    }

    @Test func aWeakShortMatchStaysUnderTheSearch() {
        // "ai" and "box" are only inside the title, "oog" only inside the address: Return still searches.
        let (state, _) = gmail()
        for query in ["ai", "box", "oog"] {
            #expect(!TabSearch.switchTargets(query, in: state).isEmpty)
            #expect(leader(query, state) == nil)
        }
        #expect(CommandBarOrder.leader("in", shown: "in", in: state, typedMatches: [], looksLikeURL: false) == nil)
    }

    @Test func typingAFavoritesSiteNameLeadsLikeItsAddress() {
        // Kite's own: "gmail" (any title) switches to the Gmail favorite on Return, rather than searching for it in the
        // tab you're on. Arc, with nothing learned, put a favorite's 5-letter title match under the search.
        var (state, mail) = gmail()
        state.update(tab: mail) { $0.title = "Inbox (3) - gabe@komadolab.com - Komado Lab Mail" }
        for query in ["gm", "gma", "gmail", " Gmail "] {
            #expect(leader(query, state) == mail)
        }
        #expect(leader("gmailx", state) == nil)
        // Sent to sign in, it still leads by its pinned page.
        state.update(tab: mail) { $0.url = URL(string: "https://accounts.google.com/v3/signin/identifier") }
        #expect(leader("gmail", state) == mail)
        // Not with a completion for something else in the field, nor when you're on it.
        #expect(CommandBarOrder.leader("gm", shown: "gmx.net", in: state, typedMatches: [], looksLikeURL: true) == nil)
        state.select(tab: mail)
        #expect(leader("gmail", state) == nil)
        // Only favorites lead by name past three letters; an open Gmail tab stays under the search.
        let (tabs, _) = gmail(favorite: false)
        #expect(leader("gmail", tabs) == nil)
        #expect(TabSearch.switchTargets("gmail", in: tabs).count == 1)
    }

    @Test func aStrongCommandStaysOnTop() {
        #expect(order(leader: "fav", tabs: [], commands: ["Copy URL"]) == ["Copy URL", "fav", "search", "e1", "e2", "h", "weak"])
    }

    @Test func noTabMatchKeepsTheSearchOrder() {
        #expect(order(leader: nil, tabs: []) == ["search", "e1", "e2", "h", "weak"])
    }
}

@Suite struct CommandBarPickTests {
    func setup() -> (BrowserState, mail: UUID, inbox: UUID) {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let mail = state.openTab(url: URL(string: "https://mail.google.com/mail/u/0/#inbox"))
        state.update(tab: mail) { $0.title = "Inbox (3) - someone@example.com - Gmail" }
        state.toggleFavorite(tab: mail)
        let inbox = state.openTab(url: URL(string: "https://mail.example.com/inbox"))
        state.update(tab: inbox) { $0.title = "Inbox (12)" }
        state.select(tab: state.openTab(url: URL(string: "https://example.com")))
        return (state, mail, inbox)
    }

    func leader(_ typed: String, _ state: BrowserState, shown: String? = nil) -> UUID? {
        let shown = shown ?? typed
        return CommandBarOrder.leader(typed, shown: shown, in: state, typedMatches: TabSearch.switchTargets(typed, in: state),
                                      looksLikeURL: URLInput.looksLikeURL(shown))?.id
    }

    @Test func aPickLeadsNextTime() {
        var (state, mail, _) = setup()
        #expect(leader("someone", state) == nil)  // Arc's order: the search first
        state.recordCommandBarPick(typed: "Someone ", tab: mail)
        #expect(leader("someone", state) == mail)
        #expect(leader("some", state) == mail)  // a shorter start of what was picked for
        #expect(leader("someonex", state) == nil)
    }

    @Test func aLaterPickReplacesAnEarlierOneAndASearchForgetsIt() {
        var (state, mail, inbox) = setup()
        state.recordCommandBarPick(typed: "inbox", tab: mail, now: Date(timeIntervalSince1970: 1))
        state.recordCommandBarPick(typed: "inbox", tab: inbox, now: Date(timeIntervalSince1970: 2))
        #expect(leader("inbox", state) == inbox)
        #expect(state.commandBarPicks.count == 1)
        state.recordCommandBarPick(typed: "inbox", tab: nil)
        #expect(leader("inbox", state) == nil)
    }

    @Test func anotherPickForTheStartForgetsLongerPicks() {
        var (state, mail, _) = setup()
        state.recordCommandBarPick(typed: "someone inbox", tab: mail)
        #expect(leader("someone", state) == mail)
        state.recordCommandBarPick(typed: "someone", tab: nil)  // searched instead
        #expect(leader("someone", state) == nil)
        #expect(state.commandBarPicks.isEmpty)
    }

    @Test func aPickedTabThatMovedOnNoLongerLeads() {
        var (state, _, inbox) = setup()
        state.recordCommandBarPick(typed: "inbox", tab: inbox)
        state.update(tab: inbox) {
            $0.url = URL(string: "https://news.example.com")
            $0.title = "News"
        }
        #expect(leader("inbox", state) == nil)
    }

    @Test func aOneLetterSearchKeepsLongerPicks() {
        var (state, mail, _) = setup()
        state.recordCommandBarPick(typed: "gmail", tab: mail)
        #expect(!state.commandBarPickChanges(typed: "g", tab: nil))
        state.recordCommandBarPick(typed: "g", tab: nil)
        #expect(state.commandBarPicks.map(\.query) == ["gmail"])
    }

    @Test func aSessionOverTheCapIsTrimmedOnTheNextPick() {
        var (state, mail, _) = setup()
        state.commandBarPicks = (0..<(BrowserState.commandBarPickLimit + 50)).map {
            CommandBarPick(query: "q\($0)", tabID: mail, pickedAt: Date(timeIntervalSince1970: Double($0)))
        }
        state.recordCommandBarPick(typed: "gmail", tab: mail)
        #expect(state.commandBarPicks.count == BrowserState.commandBarPickLimit)
        #expect(state.commandBarPicks.first?.query == "gmail")
    }

    @Test func picksForClosedTabsAreDropped() {
        var (state, mail, inbox) = setup()
        state.recordCommandBarPick(typed: "inbox", tab: inbox)
        _ = state.close(tab: inbox)
        state.recordCommandBarPick(typed: "gmail", tab: mail)
        #expect(state.commandBarPicks.map(\.query) == ["gmail"])
    }

    @Test func theNextPickIsTriedWhenTheBestIsTheTabYoureOn() {
        var (state, mail, inbox) = setup()
        state.recordCommandBarPick(typed: "inbox (", tab: inbox, now: Date(timeIntervalSince1970: 1))
        state.recordCommandBarPick(typed: "inbox", tab: mail, now: Date(timeIntervalSince1970: 2))
        state.select(tab: mail)
        #expect(leader("inbox", state) == inbox)
        #expect(state.commandBarPickChanges(typed: "inbox", tab: nil))
        #expect(!state.commandBarPickChanges(typed: "weather", tab: nil))
        // A pick also leads for URL-like text, above the Open row.
        state.recordCommandBarPick(typed: "mail.example", tab: inbox)
        #expect(leader("mail.example", state) == inbox)
    }

    @Test func anExactPickBeatsALongerOne() {
        var (state, mail, inbox) = setup()
        state.recordCommandBarPick(typed: "inbox", tab: inbox, now: Date(timeIntervalSince1970: 1))
        state.recordCommandBarPick(typed: "inbox (3)", tab: mail, now: Date(timeIntervalSince1970: 2))
        #expect(leader("inbox", state) == inbox)
        #expect(leader("inb", state) == mail)  // both start with it: the latest
    }

    @Test func aPickWaitsForItsTabAndForTheField() {
        var (state, mail, inbox) = setup()
        state.recordCommandBarPick(typed: "gi", tab: inbox)
        // A completion showing something else in the field ("gi" + "thub.com"): the pick would disagree.
        #expect(leader("gi", state, shown: "github.com") == nil)
        state.recordCommandBarPick(typed: "gmail", tab: mail)
        state.select(tab: mail)
        #expect(leader("gmail", state) == nil)  // you're on it
        _ = state.close(tab: inbox)
        #expect(leader("gi", state) == nil)  // closed
    }

    @Test func picksAreSavedCappedAndForgottenWithHistory() throws {
        var (state, mail, _) = setup()
        for i in 0..<(BrowserState.commandBarPickLimit + 5) {
            state.recordCommandBarPick(typed: "q\(i)", tab: mail, now: Date(timeIntervalSince1970: Double(i)))
        }
        #expect(state.commandBarPicks.count == BrowserState.commandBarPickLimit)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.commandBarPicks == state.commandBarPicks)
        state.forgetCommandBarPicks(since: Date(timeIntervalSince1970: 100))
        #expect(state.commandBarPicks.allSatisfy { $0.pickedAt < Date(timeIntervalSince1970: 100) })
        state.forgetCommandBarPicks(since: nil)
        #expect(state.commandBarPicks.isEmpty)
    }
}

@Suite struct LiveTabPolicyTests {
    @Test func evictsLeastRecentlyShownFirst() {
        let ids = (0..<5).map { _ in UUID() }
        var live: [UUID: Date] = [:]
        for (i, id) in ids.enumerated() { live[id] = Date(timeIntervalSince1970: Double(i)) }

        let policy = LiveTabPolicy(maxLiveTabs: 3)
        #expect(policy.tabsToEvict(live: live, protected: []) == [ids[0], ids[1]])
        #expect(policy.tabsToEvict(live: live, protected: [ids[0]]) == [ids[1], ids[2]])
        #expect(LiveTabPolicy(maxLiveTabs: 5).tabsToEvict(live: live, protected: []).isEmpty)
    }

    @Test func busyTabsAreSkippedSoTheNextOldestGoes() {
        let ids = (0..<5).map { _ in UUID() }
        var live: [UUID: Date] = [:]
        for (i, id) in ids.enumerated() { live[id] = Date(timeIntervalSince1970: Double(i)) }
        let policy = LiveTabPolicy(maxLiveTabs: 3)
        // ids[0] plays music and ids[4] is on screen: the two oldest others go, so the live count meets the cap.
        let evicted = policy.tabsToEvict(live: live, protected: [ids[4], ids[0]])
        #expect(evicted == [ids[1], ids[2]])
        #expect(live.count - evicted.count == 3)
        // More busy tabs than the cap allows: only the idle ones go, never a busy one.
        #expect(policy.tabsToEvict(live: live, protected: [ids[0], ids[1], ids[2], ids[4]]) == [ids[3]])
    }

    @Test func hibernationIsDroppedWhenTheTabChangedDuringItsBusyCheck() {
        let picked = Date(timeIntervalSince1970: 10)
        #expect(LiveTabPolicy.stillHibernates(pickedShownAt: picked, shownAt: picked, samePage: true, visible: false))
        // Shown again (and maybe hidden again) while the check ran.
        #expect(!LiveTabPolicy.stillHibernates(pickedShownAt: picked, shownAt: Date(timeIntervalSince1970: 11),
                                               samePage: true, visible: false))
        #expect(!LiveTabPolicy.stillHibernates(pickedShownAt: picked, shownAt: picked, samePage: true, visible: true))
        // Another page under the tab id (claimed from another window, or made again).
        #expect(!LiveTabPolicy.stillHibernates(pickedShownAt: picked, shownAt: picked, samePage: false, visible: false))
        // Already gone.
        #expect(!LiveTabPolicy.stillHibernates(pickedShownAt: picked, shownAt: nil, samePage: true, visible: false))
        #expect(!LiveTabPolicy.stillHibernates(pickedShownAt: nil, shownAt: nil, samePage: true, visible: false))
    }
}

@Suite struct ThemeTests {
    @Test func okLabRoundTrips() {
        for color in Theme.presets.flatMap(\.colors) {
            let back = OKLab.toSRGB(color.lab)
            #expect(abs(back.r - color.r) < 0.002)
            #expect(abs(back.g - color.g) < 0.002)
            #expect(abs(back.b - color.b) < 0.002)
        }
    }

    @Test func whiteAndBlackLightness() {
        #expect(abs(ThemeColor(hex: 0xFFFFFF).lab.x - 1) < 0.001)
        #expect(abs(ThemeColor(hex: 0x000000).lab.x) < 0.001)
    }

    @Test func foregroundFollowsLightness() {
        #expect(Theme(colors: [ThemeColor(hex: 0xF4F4F0)]).prefersDarkForeground)
        #expect(!Theme(colors: [ThemeColor(hex: 0x1F2329)]).prefersDarkForeground)
    }

    @Test func clampsColorCount() {
        let theme = Theme(colors: Array(repeating: ThemeColor(hex: 0x123456), count: 7))
        #expect(theme.colors.count == Theme.maxColors)
    }
}

@Suite struct SessionStoreTests {
    @Test func roundTripsAndQuarantinesCorruptFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(fileURL: dir.appendingPathComponent("session.json"))
        #expect(try store.load() == nil)

        var state = BrowserState.makeDefault()
        state.openTab(url: URL(string: "https://kite.example"), now: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(state)
        #expect(try store.load() == state)

        try Data("{nope".utf8).write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.contains { $0.contains("corrupt") })
    }
}

@Suite struct SessionBackupTests {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let store: SessionStore
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let hour = SessionBackups.interval
    private let day: TimeInterval = 24 * 60 * 60

    init() { store = SessionStore(fileURL: dir.appendingPathComponent("session.json")) }

    /// Made once per test: each new state has new ids, and the tests compare them.
    private let states: [BrowserState] = (0..<80).map { tabs in
        var state = BrowserState.makeDefault()
        for i in 0..<tabs { state.openTab(url: URL(string: "https://kite.example/\(i)"), now: Date(timeIntervalSince1970: 1_700_000_000)) }
        return state
    }

    private func state(tabs: Int) -> BrowserState { states[tabs] }

    @discardableResult
    private func backUp(_ state: BrowserState, _ kind: SessionBackups.Kind = .hourly, at date: Date) throws -> SessionBackups.Backup? {
        try store.backups.backUp(SessionStore.encode(state), kind: kind, now: date)
    }

    private func write(_ text: String, named name: String) throws {
        try FileManager.default.createDirectory(at: store.backups.directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: store.backups.directory.appendingPathComponent(name))
    }

    @Test func backsUpChangesAtMostOncePerInterval() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.backups.directory.lastPathComponent == "Backups")
        #expect(try backUp(state(tabs: 1), at: start) != nil)
        // Too soon, then the same bytes, then a change after the interval.
        #expect(try backUp(state(tabs: 2), at: start + 60) == nil)
        #expect(try backUp(state(tabs: 1), at: start + hour) == nil)
        let second = try #require(try backUp(state(tabs: 2), at: start + hour))
        #expect(second.url.lastPathComponent == "session.2023-11-14-23-13-20-000.json")
        // Launch and restore backups skip the interval, and name their kind.
        let launch = try #require(try backUp(state(tabs: 3), .launch, at: start + hour + 1))
        #expect(launch.url.lastPathComponent == "session.2023-11-14-23-13-21-000.launch.json")
        let all = store.backups.all()
        #expect(all.map(\.kind) == [.launch, .hourly, .hourly])
        #expect(try store.backups.state(of: all[1]) == state(tabs: 2))
        let summary = store.backups.summary(of: all[1])
        #expect(summary.spaceCount == BrowserState.makeDefault().spaces.count)
        #expect(summary.tabCount == state(tabs: 2).spaces.reduce(0) { $0 + $1.allTabs.count })
    }

    @Test func hourlyBackupsDontPushOutLaunchBackups() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<(SessionBackups.launchesKept + 3) { try backUp(state(tabs: i), .launch, at: start + Double(i)) }
        for i in 0..<40 { try backUp(state(tabs: 40 + i), at: start + 100 + Double(i) * hour) }
        let all = store.backups.all()
        #expect(all.filter { $0.kind == .launch }.count == SessionBackups.launchesKept)
        #expect(all.filter { $0.kind == .hourly }.count == 40)
        // The newest launches are the ones kept.
        #expect(all.last { $0.kind == .launch }?.date == start + 3)
        // Files that aren't backups are left alone.
        try write("", named: "notes.txt")
        store.backups.prune(now: start + 100 + 39 * hour)
        #expect(FileManager.default.fileExists(atPath: store.backups.directory.appendingPathComponent("notes.txt").path))
    }

    @Test func hourlyBackupsThinToOneADayThenExpire() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        // Every 6 hours for 40 days.
        for i in 0..<160 { try backUp(state(tabs: i % 2 == 0 ? 1 : 2), at: start + Double(i) * 6 * hour) }
        let now = start + 159 * 6 * hour
        let hourly = store.backups.all().filter { $0.kind == .hourly }
        let recent = hourly.filter { now.timeIntervalSince($0.date) <= SessionBackups.hourlyKeptFor }
        let older = hourly.filter { now.timeIntervalSince($0.date) > SessionBackups.hourlyKeptFor }
        #expect(recent.count == 9)
        #expect(older.allSatisfy { now.timeIntervalSince($0.date) <= SessionBackups.dailyKeptFor })
        let days = older.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: $0.date).day! }
        #expect(Set(days).count == days.count)
        #expect(older.count >= 27 && older.count <= 29)
    }

    @Test func futureStampsDontBlockBackupsOrRestores() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try backUp(state(tabs: 1), at: start)
        // A backup stamped a year ahead (the clock went back, or a copied folder).
        try write(String(decoding: try SessionStore.encode(state(tabs: 9)), as: UTF8.self), named: "session.2024-11-14-00-00-00-000.json")
        #expect(try backUp(state(tabs: 2), at: start + hour) != nil)
        #expect(store.backups.ordered(now: start + hour).first?.date == start + hour)
        #expect(store.backups.newestValid(now: start + hour)?.1 == state(tabs: 2))
        // A restore always keeps what it replaces.
        try store.save(state(tabs: 3))
        let old = try #require(store.backups.ordered(now: start + hour).last { $0.date == start })
        _ = try store.restore(old, current: state(tabs: 3), now: start + hour + 60)
        let kept = try #require(store.backups.all().first { $0.kind == .restore })
        #expect(try store.backups.state(of: kept) == state(tabs: 3))
    }

    @Test func corruptSessionFallsBackToNewestValidBackup() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try backUp(state(tabs: 1), at: start)
        try backUp(state(tabs: 2), at: start + hour)
        // The newest backup is damaged too, so the one before it is used.
        try write("{nope", named: "session.2023-11-15-00-00-00-000.json")
        #expect(store.backups.summary(of: store.backups.all()[0]).isRestorable == false)
        try Data("{nope".utf8).write(to: store.fileURL)
        let loaded = try #require(try store.loadRecovering())
        #expect(loaded.state == state(tabs: 2))
        #expect(loaded.recoveredFrom?.date == start + hour)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers.contains { $0.contains("corrupt") })
    }

    @Test func sessionWithNoSpacesIsCorruptNotACrash() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = Data(#"{"version":1,"state":{"spaces":[]}}"#.utf8)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try empty.write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }
        try backUp(state(tabs: 1), at: start)
        try empty.write(to: store.fileURL)
        #expect(try store.load() == state(tabs: 1))
    }

    #if !os(Windows)
    @Test func unreadableSessionIsMovedAsideNotLost() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(state(tabs: 3))
        let original = try Data(contentsOf: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        #expect(throws: (any Error).self) { try store.load() }
        // Gone from session.json, so a fresh save can't overwrite it, and kept byte for byte beside it.
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let aside = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.contains("corrupt") })
        let asideURL = dir.appendingPathComponent(aside)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: asideURL.path)
        #expect(try Data(contentsOf: asideURL) == original)
    }

    @Test func restoreRefusesToOverwriteASessionItCantMoveAside() throws {
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let old = try #require(try backUp(state(tabs: 1), at: start))
        try store.save(state(tabs: 3))
        let original = try Data(contentsOf: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        #expect(throws: SessionStore.RestoreError.self) { try store.restore(old, current: state(tabs: 3), now: start + 60) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        #expect(try Data(contentsOf: store.fileURL) == original)
    }
    #endif

    @Test func restoreKeepsTheCurrentStateAsABackup() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try #require(try backUp(state(tabs: 1), at: start))
        let current = state(tabs: 4)
        try store.save(current)
        // A minute later: under the interval, but a restore always keeps what it replaces.
        let restored = try store.restore(old, current: current, now: start + 60)
        #expect(restored == state(tabs: 1))
        #expect(try store.load() == state(tabs: 1))
        let all = store.backups.all()
        #expect(all.map(\.kind) == [.restore, .hourly])
        #expect(try store.backups.state(of: all[0]) == current)
        // Restoring that one brings the state back.
        #expect(try store.restore(all[0], current: restored, now: start + 120) == current)
        // A backup that doesn't decode changes nothing.
        try write("{nope", named: "session.2023-11-14-22-30-00-000.json")
        let bad = try #require(store.backups.all().first { $0.date == Date(timeIntervalSince1970: 1_700_001_000) })
        #expect(throws: (any Error).self) { try store.restore(bad, current: current, now: start + 180) }
        #expect(try store.load() == current)
    }

    @Test func restoreKeepsTheCurrentSettings() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        var old = state(tabs: 2)
        old.searchEngine = .duckDuckGo
        old.blocksAds = true
        _ = old.insertSpace(name: "", icon: "", theme: Theme.presets[0])
        let backup = try #require(try backUp(old, at: start))
        var current = state(tabs: 5)
        current.searchEngine = .bing
        current.blocksAds = false
        let restored = try store.restore(backup, current: current, now: start + 60)
        #expect(restored.searchEngine == .bing)
        #expect(!restored.blocksAds)
        #expect(restored.spaces.map(\.id) == state(tabs: 2).spaces.map(\.id))
        #expect(restored.spaces.flatMap(\.allTabs) == state(tabs: 2).spaces.flatMap(\.allTabs))
    }

    @Test func fallbackSkipsTheStateARestoreReplaced() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try #require(try backUp(state(tabs: 1), at: start))
        try store.save(state(tabs: 4))
        _ = try store.restore(old, current: state(tabs: 4), now: start + 60)
        // The newest backup is the rejected 4-tab state; a damaged session comes back as the restored one.
        #expect(store.backups.all().first?.kind == .restore)
        try Data("{nope".utf8).write(to: store.fileURL)
        #expect(try store.load() == state(tabs: 1))
    }

    @Test func eachKindKeepsItsOwnCopy() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try backUp(state(tabs: 1), at: start)
        // The same bytes as the newest hourly backup still get a launch backup, and then a restore one.
        #expect(try backUp(state(tabs: 1), .launch, at: start + 1) != nil)
        #expect(try backUp(state(tabs: 1), .launch, at: start + 2) == nil)
        #expect(try backUp(state(tabs: 1), .restore, at: start + 3) != nil)
        #expect(store.backups.all().map(\.kind) == [.restore, .launch, .hourly])
    }

    @Test func stampsRoundTripInUTC() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.257)
        #expect(SessionBackups.stamp(date) == "2023-11-14-22-13-20-257")
        let parsed = try #require(SessionBackups.date(from: "2023-11-14-22-13-20-257"))
        #expect(abs(parsed.timeIntervalSince(date)) < 0.0005)
        #expect(SessionBackups.stamp(Date(timeIntervalSince1970: 0)) == "1970-01-01-00-00-00-000")
        for junk in ["2023-11-14-22-13-20", "2023-13-14-22-13-20-000", "2023-11-14-22-13-20-0x0", "+023-11-14-22-13-20-000"] {
            #expect(SessionBackups.date(from: junk) == nil)
        }
    }
}

@Suite struct SavedWindowsTests {
    @Test func dropsOnlyTheWindowThatDoesntDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("windows.json")
        let blank = BrowserState(spaces: [Space(name: "Explore", icon: "🧭", theme: Theme.presets[0])])
        let good = try String(decoding: JSONEncoder().encode(SavedWindows(windows: [
            .init(kind: .blank, frame: [0, 0, 800, 600], state: blank),
        ])), as: UTF8.self)
        // The good blank window, then one whose state has no spaces, then a normal window.
        let goodWindow = try #require(good.range(of: #"\[\{.*\}\]"#, options: .regularExpression).map { String(good[$0].dropFirst().dropLast()) })
        let json = #"{"version":1,"windows":["# + goodWindow
            + #",{"kind":"blank","frame":[1,2,3,4],"state":{"spaces":[]}},{"kind":"normal","frame":[5,6,7,8]}]}"#
        try Data(json.utf8).write(to: url)
        let loaded = SavedWindows.load(from: url)
        #expect(!loaded.stuck)
        let file = try #require(loaded.file)
        #expect(file.windows.map(\.kind) == [.blank, .normal])
        #expect(file.windows[0].state?.spaces.map(\.name) == ["Explore"])
        #expect(file.dropped == 1)
        // A copy is kept before the next save rewrites the file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("windows.corrupt-") })
    }

    @Test func movesAsideAFileThatDoesntDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("windows.json")
        #expect(SavedWindows.load(from: url).file == nil)
        try Data("{nope".utf8).write(to: url)
        let loaded = SavedWindows.load(from: url)
        #expect(loaded.file == nil && !loaded.stuck)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("windows.corrupt-") })
    }

    #if !os(Windows)
    @Test func aFileThatCantBeMovedAsideIsStuck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("windows.json")
        try Data("{nope".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let loaded = SavedWindows.load(from: url)
        #expect(loaded.file == nil && loaded.stuck)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    #endif
}

@Suite struct LinkFormatTests {
    @Test func usesTitleAsLinkText() {
        let url = URL(string: "https://example.com/a")!
        #expect(LinkFormat.markdown(title: "Example", url: url) == "[Example](https://example.com/a)")
    }

    @Test func fallsBackToURLWithoutTitle() {
        let url = URL(string: "https://example.com/")!
        #expect(LinkFormat.markdown(title: "  ", url: url) == "[https://example.com/](https://example.com/)")
    }

    @Test func escapesBracketsAndParentheses() {
        let url = URL(string: "https://en.wikipedia.org/wiki/Arc_(web_browser)")!
        #expect(
            LinkFormat.markdown(title: "Arc [browser]\nwiki", url: url)
                == "[Arc \\[browser\\] wiki](https://en.wikipedia.org/wiki/Arc_%28web_browser%29)"
        )
    }

    @Test func quotesSelectionWithSource() {
        let url = URL(string: "https://example.com/")!
        #expect(
            LinkFormat.quote(selection: " First line\n\nSecond ", title: "Example", url: url)
                == "> First line\n>\n> Second\n>\n> — [Example](https://example.com/)"
        )
        #expect(LinkFormat.quote(selection: "  ", title: "Example", url: url) == "[Example](https://example.com/)")
    }
}

@Suite struct ArcCommandTests {
    private func makeState(tabs: Int) -> (BrowserState, [UUID]) {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        var ids: [UUID] = []
        for i in 0..<tabs {
            ids.append(state.openTab(url: URL(string: "https://site\(i).com"), now: Date(timeIntervalSince1970: Double(i))))
        }
        return (state, ids.reversed())
    }

    @Test func clearTodayArchivesUnpinnedTabsAndKeepsPinned() {
        var (state, ids) = makeState(tabs: 3)
        state.togglePin(tab: ids[2])
        state.select(tab: ids[0])
        let cleared = state.clearToday()
        #expect(cleared.map(\.id) == [ids[0], ids[1]])
        #expect(state.selectedSpace.tabs.isEmpty)
        #expect(state.archived.map(\.tab.id) == [ids[0], ids[1]])
        #expect(state.selectedTab?.id == ids[2])
    }

    @Test func clearTodayInSpaceLeavesOtherSpacesAlone() {
        var (state, ids) = makeState(tabs: 2)
        let first = state.selectedSpaceID
        let second = state.addSpace(name: "B", icon: "b", theme: Theme.presets[0])
        let other = state.openTab(url: URL(string: "https://b.example"))
        let cleared = state.clearToday(inSpace: first)
        #expect(Set(cleared.map(\.id)) == Set(ids))
        #expect(state.spaces[0].tabs.isEmpty)
        #expect(state.spaces[1].tabs.map(\.id) == [other])
        #expect(state.selectedSpaceID == second)
        #expect(state.clearToday(inSpace: UUID()).isEmpty)
    }

    @Test func duplicateGoesBelowTheOriginal() {
        var (state, ids) = makeState(tabs: 2)
        let copy = state.duplicate(tab: ids[0])
        #expect(state.selectedSpace.tabs.map(\.id) == [ids[0], copy!, ids[1]])
        #expect(state.tab(copy!)?.url == state.tab(ids[0])?.url)
        #expect(state.selectedTab?.id == copy)
    }

    @Test func renameIgnoresBlankNames() {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        let id = state.spaces[0].id
        state.renameSpace(id, to: "  Work ")
        #expect(state.spaces[0].name == "Work")
        state.renameSpace(id, to: "   ")
        #expect(state.spaces[0].name == "Work")
    }
}

@Suite struct CommandSearchTests {
    @Test func prefersTitlePrefixThenWordPrefixes() {
        #expect(CommandSearch.score("copy", title: "Copy URL") == 100)
        #expect(CommandSearch.score("cop url", title: "Copy URL as Markdown") == 80)
        #expect(CommandSearch.score("markdown url", title: "Copy URL as Markdown") == 80)
        #expect(CommandSearch.score("ark", title: "Copy URL as Markdown") == 50)
    }

    @Test func rejectsNonMatches() {
        #expect(CommandSearch.score("zoom", title: "Copy URL") == nil)
        #expect(CommandSearch.score("  ", title: "Copy URL") == nil)
    }
}

@Suite struct ThemeTintTests {
    @Test func sessionsWithoutTintGetTheDefault() throws {
        let json = #"{"colors":[{"r":1,"g":0.5,"b":0.25}],"grain":0.3}"#
        let theme = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
        #expect(theme.tint == Theme.defaultTint)
        #expect(theme.grain == 0.3)
    }

    @Test func tintRoundTripsAndClamps() throws {
        let theme = Theme(colors: [ThemeColor(hex: 0x3A4BC0)], tint: 1.4)
        #expect(theme.tint == 1)
        let decoded = try JSONDecoder().decode(Theme.self, from: JSONEncoder().encode(theme))
        #expect(decoded == theme)
    }

    @Test func setThemeChangesOnlyThatSpace() {
        var state = BrowserState.makeDefault(seedURL: nil)
        let other = state.spaces[1].theme
        var theme = Theme.presets[3]
        theme.tint = 0.2
        state.setTheme(theme, forSpace: state.spaces[0].id)
        #expect(state.spaces[0].theme == theme)
        #expect(state.spaces[1].theme == other)
    }
}
