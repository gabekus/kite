import AppKit
import KiteCore
import WebKit

/// Instant Links (Arc Max): ⇧⏎ on a search in the command bar. Kite's Claude turns the input
/// into one or more Google queries (like Arc's model), a hidden web view reads each query's
/// top result off Google's results page (like Arc's hidden web content), and the results
/// open as tabs, a split or a folder.
///
/// Without Claude Code the input itself is the one query; when Google gives no result (or a
/// captcha) the query's results page opens instead, as plain ⏎ would.
@MainActor
final class InstantLinksController {
    /// Arc's setting key. On unless turned off (`defaults write … instantLinksEnabled -bool NO`).
    static let enabledKey = "instantLinksEnabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private let store: BrowserStore
    private let workDirectory: URL
    /// Web views reading results, kept alive until they finish.
    private var readers: Set<ResultReader> = []

    init(store: BrowserStore, supportDirectory: URL) {
        self.store = store
        workDirectory = supportDirectory.appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("Work", isDirectory: true)
    }

    func open(_ input: String) {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard InstantLinks.applies(to: input) else { return }
        let directory = workDirectory
        // Arc's loading row in Today until the results replace it.
        let row = InstantLinks.Pending(spaceID: store.state.selectedSpace.id)
        store.instantLinksRows.insert(row, at: 0)
        Task {
            let plan = await Task.detached { Self.plan(for: input, directory: directory) }.value
                ?? .fallback(for: input)
            var urls: [URL] = []
            for query in plan.queries {
                guard let page = InstantLinks.googleURL(for: query, template: Self.searchURLTemplate) else { continue }
                urls.append(await topResult(of: page) ?? page)
            }
            // Closed while it worked: nothing opens.
            guard let index = store.instantLinksRows.firstIndex(where: { $0.id == row.id }) else { return }
            guard !urls.isEmpty else {
                store.instantLinksRows[index].status = .error
                return
            }
            store.instantLinksRows.remove(at: index)
            store.mutate { $0.openInstantLinks(urls, title: plan.title, format: plan.format, inSpace: row.spaceID) }
        }
    }

    /// Closes a row: a loading one is cancelled (its results never open).
    func dismiss(_ id: UUID) {
        store.instantLinksRows.removeAll { $0.id == id }
    }

    /// A test build (`KITE_SUPPORT_PATH`) can read results off a local page instead of Google:
    /// `KITE_TEST_INSTANT_LINKS_SEARCH_URL`, with `%s` for the query.
    nonisolated private static var searchURLTemplate: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KITE_SUPPORT_PATH"] != nil else { return nil }
        return environment["KITE_TEST_INSTANT_LINKS_SEARCH_URL"]
    }

    // MARK: Claude

    /// One headless Claude Code turn: no tools, no MCP, no saved session, the fast model.
    nonisolated private static func plan(for input: String, directory: URL) -> InstantLinks.Plan? {
        guard let claude = ClaudeConnect.findClaude() else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = [
            "-p", "--model", "haiku", "--output-format", "text",
            "--tools", "", "--strict-mcp-config", "--no-session-persistence",
            "--system-prompt", InstantLinks.systemPrompt,
        ]
        var environment = ProcessInfo.processInfo.environment
        let (status, path) = ClaudeConnect.run("/bin/zsh", ["-lc", "printf %s \"$PATH\""])
        if status == 0, path.contains("/") { environment["PATH"] = path }
        environment["KITE_DIAGNOSTICS"] = nil
        process.environment = environment
        process.currentDirectoryURL = directory
        let stdin = Pipe(), output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // A stuck model shouldn't hold the results back forever.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return InstantLinks.plan(from: String(decoding: data, as: UTF8.self), input: input)
    }

    // MARK: Google

    private func topResult(of page: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            let reader = ResultReader(page: page) { [weak self] reader, result in
                self?.readers.remove(reader)
                continuation.resume(returning: result)
            }
            readers.insert(reader)
            reader.start()
        }
    }
}

/// A web view no one sees that loads a Google results page and hands back its top result,
/// or nil on a captcha, an error or a timeout. When Google links the result through its own
/// redirect, the reader follows it and stops at the first page off Google.
@MainActor
private final class ResultReader: NSObject, WKNavigationDelegate {
    private let page: URL
    private let done: (ResultReader, URL?) -> Void
    private var webView: WKWebView?
    private var finished = false
    private var attempts = 0
    private var following = false

    init(page: URL, done: @escaping (ResultReader, URL?) -> Void) {
        self.page = page
        self.done = done
    }

    func start() {
        let configuration = WKWebViewConfiguration()
        // Google answers a cookieless browser with its "unusual traffic" page.
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Version/18.6 Safari/605.1.15"
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        webView.load(URLRequest(url: page))
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish(nil) }
    }

    private static let script = """
        (() => {
          if (document.querySelector("form#captcha-form, iframe[title='reCAPTCHA'], div#recaptcha")) return null;
          return Array.from(document.querySelectorAll(\(String(reflecting: InstantLinks.resultSelector))))
            .filter(a => a.querySelector("h3"))
            .map(a => a.href);
        })()
        """

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            // Following a redirect: the first page off Google is the result; don't load it here.
            if following, navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url,
               let host = url.host(), !host.contains("google.") {
                decisionHandler(.cancel)
                finish(url)
                return
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { if !following { read() } }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }

    private func read() {
        guard !finished, let webView else { return }
        webView.evaluateJavaScript(Self.script) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                guard let links = value as? [String] else { return self.finish(nil) }
                // Results can arrive just after the page says it has loaded.
                if links.isEmpty, self.attempts < 4 {
                    self.attempts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.read() }
                    return
                }
                guard let top = InstantLinks.topResult(fromLinks: links) else { return self.finish(nil) }
                guard InstantLinks.isGoogleRedirect(top) else { return self.finish(top) }
                self.following = true
                webView.load(URLRequest(url: top))
            }
        }
    }

    private func finish(_ result: URL?) {
        guard !finished else { return }
        finished = true
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        done(self, result)
    }
}
