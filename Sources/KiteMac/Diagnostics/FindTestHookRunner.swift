import AppKit
import KiteCore

/// Runs `FindTestHook` (`KITE_TEST_FIND`, `KITE_TEST_FIND_OPEN`) once in a window, when its selected tab's page has
/// finished loading. Test-safe runs only: on a real profile `start` reads nothing and waits for nothing.
@MainActor
final class FindTestHookRunner {
    /// Runners waiting for their page; each leaves once it has run or given up.
    private static var waiting: [FindTestHookRunner] = []

    private let hook: FindTestHook
    private weak var controller: BrowserWindowController?
    private var observer: NSObjectProtocol?

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
        runner.observer = NotificationCenter.default.addObserver(
            forName: .kitePageFinishedLoading, object: controller.pool, queue: .main
        ) { [weak runner] note in
            MainActor.assumeIsolated { runner?.pageFinished(note.userInfo?["tab"] as? UUID) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + FindTestHook.pageLoadTimeout) { [weak runner] in
            guard let runner else { return }
            log(FindTestHook.timeoutLine)
            runner.finish()
        }
    }

    private func pageFinished(_ tab: UUID?) {
        guard let controller else { return finish() }
        let page = controller.shownPage
        guard FindTestHook.runs(finishedTab: tab, selectedTab: controller.store.state.selectedTab?.id,
                                pageShown: page != nil, pageLoading: page?.isLoading ?? true) else { return }
        finish()
        controller.applyFindTestHook(hook)
    }

    private func finish() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        Self.waiting.removeAll { $0 === self }
    }

    /// One `KITE_TEST_FIND:` line on stderr, which the capture script waits for and lists in NOTES.md.
    nonisolated static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
