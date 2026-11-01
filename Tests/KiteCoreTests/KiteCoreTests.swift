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

    @Test func quitWarningIsOnByDefaultAndPersists() throws {
        var state = BrowserState(spaces: [Space(name: "A", icon: "a", theme: Theme.presets[0])])
        #expect(state.warnsBeforeQuitting)
        state.warnsBeforeQuitting = false
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
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
