import Foundation
import Testing
@testable import KiteCore

@Suite struct LiveFolderTests {
    private func pr(_ repo: String, _ number: Int, _ title: String = "") -> LivePullRequest {
        LivePullRequest(url: URL(string: "https://github.com/\(repo)/pull/\(number)")!, title: title.isEmpty ? "PR \(number)" : title)
    }

    private func setUp() -> (BrowserState, UUID) {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let folder = state.addLiveFolder(.github, inSpace: 0)
        return (state, folder)
    }

    private func titles(_ state: BrowserState, _ folder: UUID) -> [String] {
        state.folders(inSpace: 0).first { $0.id == folder }!.items.tabs.map(\.title)
    }

    private func live(_ state: BrowserState, _ folder: UUID) -> LiveFolder {
        state.folders(inSpace: 0).first { $0.id == folder }!.live!
    }

    @Test func pullRequestURLs() {
        let url = URL(string: "https://github.com/gabekus/kite/pull/12/files?w=1#diff")!
        #expect(LivePullRequest.canonicalURL(url)?.absoluteString == "https://github.com/gabekus/kite/pull/12")
        #expect(LivePullRequest.canonicalURL(URL(string: "https://github.com/gabekus/kite/issues/12")!) == nil)
        #expect(LivePullRequest.canonicalURL(URL(string: "https://example.com/a/b/pull/1")!) == nil)
        let item = pr("gabekus/kite", 7)
        #expect(item.repository == "gabekus/kite" && item.number == 7)
    }

    @Test func addingIsOncePerSpace() {
        var (state, folder) = setUp()
        #expect(state.addLiveFolder(.github, inSpace: 0) == folder)
        let made = state.folders(inSpace: 0)
        #expect(made.count == 1 && made[0].name == "Pull Requests")
    }

    @Test func refreshAddsUnreadAndDropsClosed() {
        var (state, folder) = setUp()
        state.applyLiveFolderResult(folder, items: [pr("a/b", 1), pr("a/b", 2)])
        #expect(titles(state, folder) == ["PR 1", "PR 2"])
        #expect(live(state, folder).unread.count == 2)
        let first = state.folders(inSpace: 0)[0].items.tabs[0]
        #expect(state.folders(inSpace: 0)[0].isUnread(first))

        // Opening one marks it read.
        state.select(tab: first.id)
        #expect(!state.folders(inSpace: 0)[0].isUnread(state.tab(first.id)!))

        // 1 merged, 3 opened, 2 renamed; 1 is on screen so it stays at the end.
        state.applyLiveFolderResult(folder, items: [pr("a/b", 3), pr("a/b", 2, "Renamed")])
        #expect(titles(state, folder) == ["PR 3", "Renamed", "PR 1"])
        state.spaces[0].selectedTabID = nil
        state.applyLiveFolderResult(folder, items: [pr("a/b", 3), pr("a/b", 2)])
        #expect(titles(state, folder) == ["PR 3", "PR 2"])
        #expect(Set(live(state, folder).unread.map(\.lastPathComponent)) == ["3", "2"])
    }

    @Test func removedItemsStayHidden() {
        var (state, folder) = setUp()
        state.applyLiveFolderResult(folder, items: [pr("a/b", 1), pr("a/b", 2)])
        let gone = state.folders(inSpace: 0)[0].items.tabs[0].id
        let removed = state.removePinnedTab(gone)
        #expect(removed)
        state.applyLiveFolderResult(folder, items: [pr("a/b", 1), pr("a/b", 2)])
        #expect(titles(state, folder) == ["PR 2"])
        #expect(live(state, folder).hiddenItems.map(\.lastPathComponent) == ["1"])
    }

    @Test func repositoriesAndFilters() {
        var (state, folder) = setUp()
        state.applyLiveFolderResult(folder, items: [pr("a/b", 1), pr("c/d", 2), pr("a/b", 3)])
        #expect(live(state, folder).repositories == ["a/b", "c/d"])
        state.toggleLiveFolderRepository(folder, "a/b")
        state.applyLiveFolderResult(folder, items: [pr("a/b", 1), pr("c/d", 2), pr("a/b", 3)])
        #expect(titles(state, folder) == ["PR 2"])
        #expect(live(state, folder).repositories == ["a/b", "c/d"])

        #expect(live(state, folder).filter.title == "Mixed")
        state.toggleLiveFolderFilter(folder, .reviewRequests)
        #expect(live(state, folder).filter == .createdByMe && live(state, folder).filter.title == "Created by Me")
        state.toggleLiveFolderFilter(folder, .createdByMe)
        #expect(live(state, folder).filter == .createdByMe)
        #expect(live(state, folder).filter.githubQueries == ["is:open is:pr archived:false sort:updated-desc author:@me"])
    }

    @Test func failureKeepsRows() {
        var (state, folder) = setUp()
        state.applyLiveFolderResult(folder, items: [pr("a/b", 1)])
        state.failLiveFolder(folder, error: "Not signed in to GitHub")
        #expect(titles(state, folder) == ["PR 1"])
        #expect(live(state, folder).lastError == "Not signed in to GitHub")
        state.applyLiveFolderResult(folder, items: [pr("a/b", 1)])
        #expect(live(state, folder).lastError == nil)
    }

    @Test func oldSessionsDecodeWithoutLiveFolders() throws {
        let json = #"{"id":"8D4C3E2A-1111-4C1B-9D57-2B1F0E7D9A10","name":"Reading","isExpanded":true,"items":[]}"#
        let folder = try JSONDecoder().decode(TabFolder.self, from: Data(json.utf8))
        #expect(folder.live == nil)
        let (state, _) = setUp()
        let round = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(round.folders(inSpace: 0)[0].live?.source == .github)
    }

    @Test func makingOrReviewingAPullRequest() {
        func check(_ old: String?, _ new: String) -> Bool {
            BrowserState.isPullRequestCreatedOrReviewed(from: old.flatMap(URL.init(string:)), to: URL(string: new)!)
        }
        #expect(check("https://github.com/a/b/compare/main...topic?expand=1", "https://github.com/a/b/pull/9"))
        #expect(check("https://github.com/a/b/pull/new/topic", "https://github.com/a/b/pull/9"))
        #expect(check("https://github.com/a/b/pull/9/files", "https://github.com/a/b/pull/9#pullrequestreview-123"))
        #expect(!check("https://github.com/a/b/pulls", "https://github.com/a/b/pull/9"))
        #expect(!check("https://github.com/x/y/compare/main...topic", "https://github.com/a/b/pull/9"))
        #expect(!check(nil, "https://github.com/a/b/pull/9"))
    }

    @Test func filingAPullRequestMakesTheFolderOnce() {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let space = state.spaces[0].id
        let tab = state.openTab(url: URL(string: "https://github.com/a/b/pull/9"), in: space, select: true)
        let filed = state.filePullRequest(tab: tab)
        #expect(filed?.created == true)
        let folder = state.liveFolder(.github, inSpace: 0)!
        #expect(folder.id == filed?.folder && folder.items.tabs.map(\.id) == [tab])
        #expect(state.filePullRequest(tab: tab) == nil)

        // A second one joins the folder; deleting the folder stops it coming back.
        let other = state.openTab(url: URL(string: "https://github.com/a/b/pull/10"), in: space, select: true)
        #expect(state.filePullRequest(tab: other)?.created == false)
        state.deleteLiveFolder(folder.id)
        #expect(state.liveFoldersTurnedOff == [.github])
        let third = state.openTab(url: URL(string: "https://github.com/a/b/pull/11"), in: space, select: true)
        #expect(state.filePullRequest(tab: third) == nil)
        state.addLiveFolder(.github, inSpace: 0)
        #expect(state.liveFoldersTurnedOff.isEmpty)
    }
}
