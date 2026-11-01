import AppKit
import KiteCore

/// Keeps live folders (KiteCore's LiveFolders.swift) filled. As in Arc, a refresh reads
/// github.com with the space's own signed-in session, in a page that's never shown or listed as a
/// tab (Arc's `HTMLClient`), rather than through a GitHub token. Refreshes follow events, as Arc's
/// do (`LiveFolderFetchReason`): launch, Kite coming to the front, switching to the folder's space,
/// opening or leaving one of its tabs, a filter change, and Refresh. Arc throttles automatic ones to
/// one every 10 seconds (`automatic-live-folders-min-refresh-interval-in-seconds`).
@MainActor
final class LiveFoldersController {
    /// The app's controller, for the sidebar's menus.
    static weak var shared: LiveFoldersController?

    private let store: BrowserStore
    /// The app's engine; each space's profile gets its own (its cookies are its GitHub sign-in).
    private let engine: WebEngine
    /// Where the hidden pages live: Chromium's browsers want a window.
    private let host: () -> NSView?
    private var fetches: [UUID: GitHubPullRequestFetch] = [:]
    private var lastStarted: [UUID: Date] = [:]
    private var lastSelection: (space: UUID?, tab: UUID?) = (nil, nil)
    private var activeObserver: NSObjectProtocol?

    static let minimumInterval: TimeInterval = 10

    init(store: BrowserStore, engine: WebEngine, host: @escaping () -> NSView?) {
        self.store = store
        self.engine = engine
        self.host = host
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCurrentSpace() }
        }
        observeSelection()
        // After launch, once the window and its pages are up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refreshAll() }
    }

    /// The space menu's Live Folders → GitHub: adds the folder and fills it, or deletes it.
    func toggle(_ source: LiveFolder.Source, inSpace id: UUID) {
        guard let index = store.state.spaceIndex(id) else { return }
        if let existing = store.state.liveFolder(source, inSpace: index) {
            delete(existing.id)
        } else {
            let folder = store.mutate { $0.addLiveFolder(source, inSpace: index) }
            refresh(folder, force: true)
        }
    }

    func delete(_ id: UUID) {
        fetches.removeValue(forKey: id)?.cancel()
        store.mutate { $0.deleteLiveFolder(id) }
    }

    func toggleFilter(_ id: UUID, _ filter: LiveFolder.Filter) {
        store.mutate { $0.toggleLiveFolderFilter(id, filter) }
        refresh(id, force: true)
    }

    func toggleRepository(_ id: UUID, _ repository: String) {
        store.mutate { $0.toggleLiveFolderRepository(id, repository) }
        refresh(id, force: true)
    }

    func isRefreshing(_ id: UUID) -> Bool { fetches[id] != nil }

    /// A tab's page changed in `window` (any normal window's store). A pull request the user just made
    /// or reviewed goes into the space's Pull Requests folder, made for it if need be, as in Arc; a new
    /// folder shows its intro popover the first time, 0.1 s later (Arc's presenter delay).
    func tabURLChanged(_ id: UUID, from old: URL?, to new: URL, in window: BrowserStore) {
        guard window === store || window.link != nil, BrowserState.isPullRequestCreatedOrReviewed(from: old, to: new),
              let filed = store.mutate({ $0.filePullRequest(tab: id) }) else { return }
        // Not from inside the engine's navigation callback: a page made there never loads.
        DispatchQueue.main.async { self.refresh(filed.folder, force: true) }
        guard filed.created, !store.state.hasSeenLiveFolderIntro else { return }
        store.mutate { $0.hasSeenLiveFolderIntro = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { window.liveFolderIntroID = filed.folder }
    }

    func refreshAll() {
        for (_, folder) in store.state.liveFolders { refresh(folder.id, force: false) }
    }

    private func refreshCurrentSpace() {
        let s = store.state.selectedSpaceIndex
        for folder in store.state.folders(inSpace: s) where folder.live != nil { refresh(folder.id, force: false) }
    }

    /// Starts a refresh unless one is running, or (for an automatic one) one started in the last 10 seconds.
    func refresh(_ id: UUID, force: Bool) {
        guard fetches[id] == nil, let found = store.state.liveFolders.first(where: { $0.folder.id == id }),
              let live = found.folder.live else { return }
        if !force, let last = lastStarted[id], Date().timeIntervalSince(last) < Self.minimumInterval { return }
        lastStarted[id] = Date()
        let state = store.state
        let profileEngine = engine.profileDirectory == nil
            ? engine : engine.forProfile(state.profile(state.spaces[found.space].profile))
        switch live.source {
        case .github:
            let fetch = GitHubPullRequestFetch(queries: live.filter.githubQueries, engine: profileEngine, host: host()) { [weak self] result in
                guard let self else { return }
                self.fetches[id] = nil
                switch result {
                case .success(let items): self.store.mutate { $0.applyLiveFolderResult(id, items: items) }
                case .failure(let error): self.store.mutate { $0.failLiveFolder(id, error: error.message) }
                }
            }
            fetches[id] = fetch
            fetch.start()
        }
    }

    /// Switching spaces, or opening or leaving one of a live folder's tabs, refreshes that space's folders.
    private func observeSelection() {
        withObservationTracking {
            _ = store.state
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.selectionChanged()
                self.observeSelection()
            }
        }
    }

    private func selectionChanged() {
        let state = store.state
        let space = state.spaces[state.selectedSpaceIndex]
        let now = (space: Optional(space.id), tab: space.selectedTabID)
        defer { lastSelection = now }
        guard now.space != lastSelection.space || now.tab != lastSelection.tab else { return }
        if now.space != lastSelection.space { return refreshCurrentSpace() }
        let touched = [lastSelection.tab, now.tab].compactMap { $0 }
        for folder in state.folders(inSpace: state.selectedSpaceIndex) where folder.live != nil {
            if folder.items.contains(where: { touched.contains($0.id) }) { refresh(folder.id, force: false) }
        }
    }
}

/// Reads the user's open pull requests from github.com: each query's results page loads in a hidden
/// page with the profile's cookies, and a script lists the pull request links on it.
@MainActor
final class GitHubPullRequestFetch {
    struct Failure: Error {
        let message: String
        static let signedOut = Failure(message: "Not signed in to GitHub")
        static let unreachable = Failure(message: "We're having trouble connecting to GitHub")
    }

    private var queries: [String]
    private let engine: WebEngine
    private weak var host: NSView?
    private let completion: (Result<[LivePullRequest], Failure>) -> Void
    private var page: WebPage?
    private var poll: Timer?
    private var results: [[LivePullRequest]] = []
    private var finished = false

    /// How long one results page gets to show its list (GitHub renders some of it after load).
    private static let pageTimeout: TimeInterval = 12
    /// A page with no pull request links after this long has none.
    private static let emptyAfter: TimeInterval = 6

    init(queries: [String], engine: WebEngine, host: NSView?, completion: @escaping (Result<[LivePullRequest], Failure>) -> Void) {
        self.queries = queries
        self.engine = engine
        self.host = host
        self.completion = completion
    }

    func start() { next() }

    func cancel() {
        finished = true
        tearDown()
    }

    /// A test run (KITE_DIAGNOSTICS=1 on a throwaway profile) can read another page instead, such as a
    /// public repository's pull requests, since its profile isn't signed in to GitHub.
    private static let testURL: URL? = UIDiagnostics.enabledByEnvironment
        ? ProcessInfo.processInfo.environment["KITE_TEST_LIVE_FOLDER_URL"].flatMap(URL.init(string:)) : nil

    static func searchURL(_ query: String) -> URL {
        if let testURL { return testURL }
        var components = URLComponents(string: "https://github.com/pulls")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }

    private func next() {
        tearDown()
        guard !finished else { return }
        guard !queries.isEmpty else { return finish(.success(Self.merge(results))) }
        load(Self.searchURL(queries.removeFirst()), retrying: true)
    }

    /// Loads one results page and reads it. A page whose script never answers (now and then a hidden
    /// page never starts) gets one fresh try.
    private func load(_ url: URL, retrying: Bool) {
        tearDown()
        let page = engine.makePage(url: url, restoring: nil)
        if let host {
            // Window-sized: GitHub only renders the rows that fit, so a 1×1 page lists two.
            page.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 4000)
            page.view.isHidden = true
            host.addSubview(page.view, positioned: .below, relativeTo: nil)
        }
        self.page = page
        let started = Date()
        var lastCount = -1
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let page = self.page else { return }
                page.evaluateJavaScript(Self.script) { [weak self] value in
                    guard let self, self.page === page, let report = Self.decode(value) else { return }
                    let elapsed = Date().timeIntervalSince(started)
                    if report.signedIn == false, report.onSignInPage || Self.testURL == nil {
                        return self.finish(.failure(.signedOut))
                    }
                    let count = report.items.count
                    // Done once the list stops growing, or stays empty for a while after loading.
                    if report.ready && ((count > 0 && count == lastCount) || (count == 0 && elapsed > Self.emptyAfter)) {
                        self.results.append(report.items)
                        return self.next()
                    }
                    lastCount = count
                    if elapsed > Self.pageTimeout {
                        NSLog("Kite: live folder page never settled (ready: \(report.ready), \(count) pull requests)")
                        self.finish(.failure(.unreachable))
                    }
                }
                if Date().timeIntervalSince(started) > Self.pageTimeout + 2 {
                    NSLog("Kite: live folder page didn't answer\(retrying ? ", trying again" : "")")
                    if retrying { return self.load(url, retrying: false) }
                    self.finish(.failure(.unreachable))
                }
            }
        }
    }

    private func finish(_ result: Result<[LivePullRequest], Failure>) {
        guard !finished else { return }
        finished = true
        tearDown()
        completion(result)
    }

    private func tearDown() {
        poll?.invalidate()
        poll = nil
        if let page {
            page.onEvent = nil
            page.view.removeFromSuperview()
            page.close()
        }
        page = nil
    }

    /// Each query's results, newest first, without repeats. With dates on every row, sorted by them.
    static func merge(_ lists: [[LivePullRequest]]) -> [LivePullRequest] {
        var seen = Set<URL>()
        let all = lists.joined().filter { seen.insert($0.url).inserted }
        guard all.allSatisfy({ $0.updatedAt != nil }) else { return all }
        return all.enumerated().sorted { a, b in
            a.element.updatedAt! != b.element.updatedAt! ? a.element.updatedAt! > b.element.updatedAt! : a.offset < b.offset
        }.map(\.element)
    }

    struct Report {
        var signedIn: Bool?
        var onSignInPage: Bool
        var ready: Bool
        var items: [LivePullRequest]
    }

    static func decode(_ value: Any?) -> Report? {
        guard let text = value as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // GitHub writes times with milliseconds (2026-11-01T17:07:11.000Z).
        let dates = ISO8601DateFormatter(), whole = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let items = (object["items"] as? [[String: Any]] ?? []).compactMap { item -> LivePullRequest? in
            guard let href = item["url"] as? String, let url = URL(string: href).flatMap(LivePullRequest.canonicalURL) else { return nil }
            let updated = (item["updated"] as? String).flatMap { dates.date(from: $0) ?? whole.date(from: $0) }
            return LivePullRequest(url: url, title: item["title"] as? String ?? "", updatedAt: updated)
        }
        return Report(signedIn: object["signedIn"] as? Bool, onSignInPage: object["signInPage"] as? Bool ?? false, ready: object["ready"] as? Bool ?? false, items: items)
    }

    /// Lists the page's pull requests (github.com/owner/name/pull/N) from the rows' title links,
    /// so a row's links to other pull requests don't count, with their titles and updated times. `signedIn` is false on GitHub's sign-in page, or a page whose
    /// `user-login` meta tag is empty.
    static let script = #"""
    (() => {
      if (location.host !== 'github.com') return JSON.stringify({ ready: false, items: [] });
      const path = location.pathname;
      if (path.startsWith('/login') || path.startsWith('/session')) return JSON.stringify({ signedIn: false, signInPage: true, ready: true, items: [] });
      const login = document.querySelector('meta[name="user-login"]');
      const signedIn = login ? login.content.length > 0 : null;
      const found = new Map();
      // Each row's title link (today's list, then the older one); any pull request link when neither is there.
      const titles = document.querySelectorAll('a[data-testid="listitem-title-link"][href*="/pull/"], a.js-navigation-open[href*="/pull/"], a[id^="issue_"][href*="/pull/"]');
      for (const a of titles.length ? titles : document.querySelectorAll('a[href*="/pull/"]')) {
        let u;
        try { u = new URL(a.getAttribute('href'), location.href); } catch (e) { continue; }
        if (u.host !== 'github.com') continue;
        const p = u.pathname.split('/').filter(Boolean);
        if (p.length !== 4 || p[2] !== 'pull' || !/^\d+$/.test(p[3])) continue;
        const key = 'https://github.com/' + p.join('/');
        const text = (a.textContent || '').replace(/\s+/g, ' ').trim();
        const row = a.closest('[id^="issue_"], li, [role="listitem"], [role="row"]');
        const time = row && row.querySelector('relative-time[datetime], time[datetime]');
        const updated = time ? time.getAttribute('datetime') : null;
        const item = found.get(key);
        if (!item) { found.set(key, { url: key, title: /^#?\d+$/.test(text) ? '' : text, updated }); continue; }
        if (text.length > item.title.length && !/^#?\d+$/.test(text)) item.title = text;
        if (!item.updated && updated) item.updated = updated;
      }
      return JSON.stringify({ signedIn, ready: document.readyState === 'complete', items: [...found.values()] });
    })()
    """#
}
