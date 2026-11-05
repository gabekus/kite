import AppKit
import KiteCore
import WebKit

/// Runs `FindTestHook` (`KITE_TEST_FIND`, `KITE_TEST_FIND_OPEN`) once in a window, when its selected tab's page has
/// finished loading. Test-safe runs only: on a real profile `start` reads nothing and waits for nothing.
///
/// It runs on the first finished-load notification for the selected tab, or, looking every half second, once the
/// selected tab's page is shown, not loading and at full progress (a load that finished before it was armed). It
/// writes `KITE_TEST_FIND: armed: …` when it starts waiting and, if it gives up, what it saw.
@MainActor
final class FindTestHookRunner {
    /// This run's hook, read once (WebKitPage keeps covered pages answering when there is one).
    nonisolated static let configured = FindTestHook.from(environment: ProcessInfo.processInfo.environment,
                                                          testSafe: WindowPresenter.testSafe)

    /// Runners waiting for their page; each leaves once it has run or given up.
    private static var waiting: [FindTestHookRunner] = []
    private static let pollInterval: Double = 0.5

    private let hook: FindTestHook
    private weak var controller: BrowserWindowController?
    private var observer: NSObjectProtocol?
    private var wait = FindTestHook.Wait()
    private var done = false

    private init(hook: FindTestHook, controller: BrowserWindowController) {
        self.hook = hook
        self.controller = controller
    }

    static func start(in controller: BrowserWindowController,
                      environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard WindowPresenter.testSafe else { return }
        if let text = environment[FindTestHook.queryKey], !text.isEmpty, let why = FindTestHook.refusal(text) {
            log(FindTestHook.refusedLine(why))
        }
        guard let hook = FindTestHook.from(environment: environment, testSafe: WindowPresenter.testSafe) else { return }
        let runner = FindTestHookRunner(hook: hook, controller: controller)
        waiting.append(runner)
        log(FindTestHook.armedLine(hook, coveredPagesAnswer: configured != nil,
                                   windowVisible: controller.window?.occlusionState.contains(.visible) == true))
        runner.observer = NotificationCenter.default.addObserver(
            forName: .kitePageFinishedLoading, object: controller.pool, queue: .main
        ) { [weak runner] note in
            MainActor.assumeIsolated { runner?.pageFinished(note.userInfo?["tab"] as? UUID) }
        }
        runner.poll(until: Date().addingTimeInterval(FindTestHook.pageLoadTimeout))
    }

    private func pageFinished(_ tab: UUID?) {
        guard let controller else { return finish() }
        let selected = controller.store.state.selectedTab?.id
        wait.loads += 1
        if tab != nil, tab == selected { wait.selectedLoads += 1 }
        let page = controller.shownPage
        guard FindTestHook.runs(finishedTab: tab, selectedTab: selected, pageShown: page != nil,
                                pageLoading: page?.isLoading ?? true) else { return }
        run(in: controller)
    }

    /// Looks at the selected tab every half second until it runs or `deadline` passes.
    private func poll(until deadline: Date) {
        guard !done else { return }
        guard let controller else { return finish() }
        let selected = controller.store.state.selectedTab?.id
        let status = selected.flatMap { controller.store.pages[$0] }
        if FindTestHook.runs(selectedTab: selected, pageShown: controller.shownPage != nil,
                             pageLoading: status?.isLoading, progress: status?.progress) {
            return run(in: controller)
        }
        guard Date() < deadline else {
            wait.selectedTab = selected != nil
            wait.pageShown = controller.shownPage != nil
            wait.pageLoading = status?.isLoading
            wait.progress = status?.progress
            wait.windowVisible = controller.window?.occlusionState.contains(.visible) == true
            if let webView = (controller.shownPage as? WebKitPage)?.webView {
                wait.webViewLoading = webView.isLoading
                wait.webViewProgress = webView.estimatedProgress
                wait.webViewHasURL = webView.url != nil
                wait.contentProcess = Self.contentProcess(of: webView)
            }
            wait.windowOrderedIn = controller.window?.isVisible == true
            wait.windowOnScreen = controller.window?.screen != nil
            wait.screens = NSScreen.screens.count
            wait.contentProcessEnds = Self.contentProcessEnds
            Self.log(FindTestHook.timeoutLine(wait))
            // The page never loaded (W21's headless runs: no page loads there at all), but the bar doesn't need it:
            // open it anyway, so an empty bar can still be captured; a query shows no result, and the line says so.
            finish()
            if controller.applyFindTestHook(hook, fallback: true) { Self.log(FindTestHook.fallbackLine(hook)) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
            self?.poll(until: deadline)
        }
    }

    private func run(in controller: BrowserWindowController) {
        guard !done else { return }
        finish()
        controller.applyFindTestHook(hook)
    }

    private func finish() {
        done = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        Self.waiting.removeAll { $0 === self }
    }

    /// One `KITE_TEST_FIND:` line on stderr, which the capture script waits for and lists in NOTES.md.
    nonisolated static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Times a page's web content process ended on this run (WebKitPage), for the give-up line.
    private(set) static var contentProcessEnds = 0

    /// The web content process WebKit runs for `webView` (its private `_webProcessIdentifier`): 0 for none, nil when
    /// this WebKit doesn't say.
    static func contentProcess(of webView: WKWebView) -> Int? {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")) else { return nil }
        return (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.intValue
    }

    /// Right after WebKitPage asks WebKit to load (and again 2 s later), on a run with a find hook only: whether the
    /// load took and whether the page has a web content process. W21's headless runs ended with no URL, no load and
    /// no navigation callback, so this says whether WebKit dropped the load at once or later.
    /// A tab's page being made, on a run with a find hook only: whether it loads a URL or restores a saved state.
    static func logPageMade(hasURL: Bool, restoredFrom source: PageRestore.Source) {
        guard configured != nil else { return }
        log(FindTestHook.pageMadeLine(hasURL: hasURL, restoredFrom: source))
    }

    static func logLoadAsked(_ webView: WKWebView) {
        guard configured != nil else { return }
        func line(_ when: String) -> String {
            FindTestHook.loadLine(when, urlSet: webView.url != nil, loading: webView.isLoading,
                                  progress: webView.estimatedProgress, contentProcess: contentProcess(of: webView))
        }
        log(line("load asked"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak webView] in
            guard let webView else { return }
            log(FindTestHook.loadLine("2 s after the load", urlSet: webView.url != nil, loading: webView.isLoading,
                                      progress: webView.estimatedProgress, contentProcess: contentProcess(of: webView)))
        }
    }

    /// A page milestone from WebKit's navigation delegate, on a run with a find hook only (nothing otherwise): where
    /// a headless load stops. An error gives its domain and code only.
    static func logPage(_ milestone: String, error: Error? = nil) {
        guard configured != nil else { return }
        if milestone == "content process ended" { contentProcessEnds += 1 }
        let nsError = error.map { $0 as NSError }
        log(FindTestHook.pageLine(milestone, error: nsError.map { ($0.domain, $0.code) }))
    }
}
