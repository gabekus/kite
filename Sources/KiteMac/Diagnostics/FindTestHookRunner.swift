import AppKit
import KiteCore

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
            Self.log(FindTestHook.timeoutLine(wait))
            return finish()
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
}
