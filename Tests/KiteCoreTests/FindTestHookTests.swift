import Foundation
import Testing
@testable import KiteCore

struct FindTestHookTests {
    private let testSafe = ["KITE_DIAGNOSTICS": "1", "KITE_SUPPORT_PATH": "/tmp/k.abcd"]

    @Test func aRealProfileIgnoresBothHooks() {
        // No KITE_SUPPORT_PATH, or no KITE_DIAGNOSTICS: not test-safe, so the find bar is never opened by a hook.
        for environment in [["KITE_DIAGNOSTICS": "1"], ["KITE_SUPPORT_PATH": "/tmp/k.abcd"], [:]] {
            let safe = WindowPresentation.isTestSafe(environment: environment)
            #expect(!safe)
            for hook in [["KITE_TEST_FIND": "domain"], ["KITE_TEST_FIND_OPEN": "1"]] {
                #expect(FindTestHook.from(environment: environment.merging(hook) { $1 }, testSafe: safe) == nil)
            }
        }
        #expect(FindTestHook.from(environment: ["KITE_TEST_FIND": "domain", "KITE_TEST_FIND_OPEN": "1"], testSafe: false) == nil)
    }

    @Test func aTestSafeRunOpensTheBarAndSetsTheQuery() {
        let safe = WindowPresentation.isTestSafe(environment: testSafe)
        #expect(safe)
        let open = FindTestHook.from(environment: testSafe.merging(["KITE_TEST_FIND_OPEN": "1"]) { $1 }, testSafe: safe)
        #expect(open == .open)
        #expect(open?.steps == [.showFind(askOnPage: false)])
        let query = FindTestHook.from(environment: testSafe.merging(["KITE_TEST_FIND": "domain"]) { $1 }, testSafe: safe)
        #expect(query == .query("domain"))
        // The bar opens as ⌘F opens it, then the query goes through the field's own path (setQuery), never keys.
        #expect(query?.steps == [.showFind(askOnPage: false), .setQuery("domain")])
    }

    @Test func theHookedBarNeverHasAskOnPage() {
        // Whatever the test app's saved askOnPageEnabled says: the plain find bar, no Ask button (which runs Claude).
        #expect(!FindTestHook.asksOnPage)
        for hook in [FindTestHook.open, .query("domain"), .query("zqxj")] {
            for step in hook.steps {
                if case .showFind(let askOnPage) = step { #expect(!askOnPage, "\(hook)") }
            }
            #expect(hook.steps.first == .showFind(askOnPage: false))
        }
    }

    @Test func aQueryWinsAndAnEmptyOneIsOff() {
        // A query wins over the empty bar; an empty query is off, which leaves KITE_TEST_FIND_OPEN.
        #expect(FindTestHook.from(environment: ["KITE_TEST_FIND": "zqxj", "KITE_TEST_FIND_OPEN": "1"], testSafe: true) == .query("zqxj"))
        #expect(FindTestHook.from(environment: ["KITE_TEST_FIND": "", "KITE_TEST_FIND_OPEN": "1"], testSafe: true) == .open)
    }

    @Test func openTakesExactlyOne() {
        for value in ["", "0", "true", "yes", " 1", "1 ", "11"] {
            #expect(FindTestHook.from(environment: ["KITE_TEST_FIND_OPEN": value], testSafe: true) == nil, "\(value)")
        }
    }

    @Test func aQueryIsOneShortLineWithoutControlCharacters() {
        for bad in ["a\nb", "a\rb", "a\tb", "\u{1B}", "a\u{7F}", "a\u{2028}b", "\u{F700}", String(repeating: "x", count: 101)] {
            #expect(FindTestHook.refusal(bad) != nil, "\(bad.debugDescription)")
            #expect(FindTestHook.from(environment: ["KITE_TEST_FIND": bad], testSafe: true) == nil, "\(bad.debugDescription)")
        }
        // Refused, it doesn't fall back to opening the bar empty.
        #expect(FindTestHook.from(environment: ["KITE_TEST_FIND": "a\nb", "KITE_TEST_FIND_OPEN": "1"], testSafe: true) == nil)
        for good in ["domain", "zqxj", "Example Domain", "a.b_c-d", String(repeating: "x", count: 100)] {
            #expect(FindTestHook.refusal(good) == nil, "\(good)")
        }
    }

    @Test func itRunsOnTheSelectedTabsLoadedShownPage() {
        let tab = UUID(), other = UUID()
        #expect(FindTestHook.runs(finishedTab: tab, selectedTab: tab, pageShown: true, pageLoading: false))
        #expect(!FindTestHook.runs(finishedTab: other, selectedTab: tab, pageShown: true, pageLoading: false))
        #expect(!FindTestHook.runs(finishedTab: nil, selectedTab: nil, pageShown: true, pageLoading: false))
        #expect(!FindTestHook.runs(finishedTab: tab, selectedTab: tab, pageShown: false, pageLoading: false))
        #expect(!FindTestHook.runs(finishedTab: tab, selectedTab: tab, pageShown: true, pageLoading: true))
    }

    @Test func itsLinesSayWhenTheBarIsReady() {
        // The capture script waits for "KITE_TEST_FIND: ready" before it captures.
        #expect(FindTestHook.openLine == "KITE_TEST_FIND: ready: open, empty")
        #expect(FindTestHook.resultLine(query: "domain", found: true, matches: 2, activeMatch: 1, counter: "1/2")
            == "KITE_TEST_FIND: ready: \"domain\", found, 2 matches, active 1, counter \"1/2\"")
        #expect(FindTestHook.resultLine(query: "zqxj", found: false, matches: nil, activeMatch: nil, counter: "Not Found")
            == "KITE_TEST_FIND: ready: \"zqxj\", not found, counter \"Not Found\"")
        #expect(!FindTestHook.timeoutLine(FindTestHook.Wait()).contains("ready"))
        #expect(!FindTestHook.refusedLine("x").contains("ready"))
        #expect(!FindTestHook.armedLine(.open, coveredPagesAnswer: true, windowVisible: false).contains("ready"))
    }

    @Test func aLookAtTheSelectedTabRunsOnlyOnceItsPageHasLoaded() {
        // For a load that finished before the hook was armed (or a notification that didn't match).
        let tab = UUID()
        #expect(FindTestHook.runs(selectedTab: tab, pageShown: true, pageLoading: false, progress: 1))
        #expect(!FindTestHook.runs(selectedTab: tab, pageShown: true, pageLoading: false, progress: 0))   // not started
        #expect(!FindTestHook.runs(selectedTab: tab, pageShown: true, pageLoading: true, progress: 1))
        #expect(!FindTestHook.runs(selectedTab: tab, pageShown: true, pageLoading: nil, progress: nil))
        #expect(!FindTestHook.runs(selectedTab: tab, pageShown: false, pageLoading: false, progress: 1))
        #expect(!FindTestHook.runs(selectedTab: nil, pageShown: true, pageLoading: false, progress: 1))
    }

    @Test func aFindHookKeepsCoveredPagesAnswering() {
        // A test-safe window is behind the user's windows, where WebKit stops an occluded window's page.
        #expect(FindTestHook.keepsCoveredPagesAnswering(environment: ["KITE_TEST_FIND": "domain"], testSafe: true))
        #expect(FindTestHook.keepsCoveredPagesAnswering(environment: ["KITE_TEST_FIND_OPEN": "1"], testSafe: true))
        #expect(!FindTestHook.keepsCoveredPagesAnswering(environment: [:], testSafe: true))
        #expect(!FindTestHook.keepsCoveredPagesAnswering(environment: ["KITE_TEST_FIND": "domain"], testSafe: false))
        #expect(!FindTestHook.keepsCoveredPagesAnswering(environment: ["KITE_TEST_FIND": "a\nb"], testSafe: true))
    }

    @Test func theDiagnosticLinesSayWhatTheHookSaw() {
        #expect(FindTestHook.armedLine(.query("domain"), coveredPagesAnswer: true, windowVisible: false)
            == "KITE_TEST_FIND: armed: query \"domain\"; waiting up to 20 s for the selected tab's page to load "
            + "(covered pages answer: yes, window visible: no)")
        #expect(FindTestHook.armedLine(.open, coveredPagesAnswer: false, windowVisible: true).hasPrefix("KITE_TEST_FIND: armed: open, empty;"))
        var wait = FindTestHook.Wait()
        wait.loads = 3
        wait.selectedLoads = 1
        wait.selectedTab = true
        wait.pageShown = true
        wait.pageLoading = true
        wait.progress = 0.1
        wait.webViewLoading = true
        wait.webViewProgress = 0.1
        wait.webViewHasURL = true
        wait.windowOrderedIn = true
        wait.screens = 1
        wait.contentProcessEnds = 2
        wait.contentProcess = 0
        #expect(FindTestHook.timeoutLine(wait)
            == "KITE_TEST_FIND: no page finished loading in 20 s, so the find bar opens without it (finished loads seen: 3, "
            + "of the selected tab: 1; selected tab: yes, page shown: yes, loading: yes, progress: 0.10; web view loading: "
            + "yes, web view progress: 0.10, web view URL set: yes, content process ended: 2 times, content process: none; "
            + "window visible: no, ordered in: yes, on a screen: no, screens: 1)")
        #expect(FindTestHook.timeoutLine(FindTestHook.Wait()).contains("loading: unknown, progress: unknown; web view loading: unknown"))
        #expect(FindTestHook.timeoutLine(FindTestHook.Wait()).contains("content process: unknown;"))
    }

    @Test func theLoadLineSaysWhetherWebKitTookTheLoad() {
        // Straight after webView.load WebKit has set the URL and loading; a page with no web content process can't load.
        #expect(FindTestHook.loadLine("load asked", urlSet: true, loading: true, progress: 0.1, contentProcess: 4321)
            == "KITE_TEST_FIND: page: load asked (web view URL set: yes, loading: yes, progress: 0.10, content process: running)")
        #expect(FindTestHook.loadLine("2 s after the load", urlSet: false, loading: false, progress: 0, contentProcess: 0)
            == "KITE_TEST_FIND: page: 2 s after the load (web view URL set: no, loading: no, progress: 0.00, content process: none)")
        #expect(FindTestHook.processText(nil) == "unknown")
        #expect(!FindTestHook.loadLine("load asked", urlSet: true, loading: true, progress: 0, contentProcess: nil).contains("ready"))
    }

    @Test func whenThePageNeverLoadsTheBarOpensAnywayAndSaysSo() {
        // The capture script waits for "KITE_TEST_FIND: ready"; the fallback's line starts so too, and says why.
        #expect(FindTestHook.fallbackLine(.open) == "KITE_TEST_FIND: ready (fallback, the page never loaded): open, empty")
        #expect(FindTestHook.fallbackLine(.query("domain"))
            == "KITE_TEST_FIND: ready (fallback, the page never loaded): \"domain\" set, no find result")
        for hook in [FindTestHook.open, .query("zqxj")] {
            #expect(FindTestHook.fallbackLine(hook).hasPrefix("KITE_TEST_FIND: ready"))
        }
        // In time for the script, whose 30 s wait starts only once Kite's socket answers.
        #expect(FindTestHook.pageLoadTimeout <= 20)
        // A fallback query only puts its text in the field: no searching step, so no result line can follow.
        #expect(FindTestHook.query("domain").steps(fallback: true) == [.showFind(askOnPage: false), .setTextOnly("domain")])
        #expect(!FindTestHook.query("zqxj").steps(fallback: true).contains(.setQuery("zqxj")))
        #expect(FindTestHook.open.steps(fallback: true) == FindTestHook.open.steps)
        #expect(FindTestHook.query("domain").steps == [.showFind(askOnPage: false), .setQuery("domain")])
    }

    @Test func pageMilestonesGiveOnlyAnErrorsDomainAndCode() {
        #expect(FindTestHook.pageLine("started") == "KITE_TEST_FIND: page: started")
        #expect(FindTestHook.pageLine("failed before commit", error: ("NSURLErrorDomain", -1003))
            == "KITE_TEST_FIND: page: failed before commit (NSURLErrorDomain -1003)")
        #expect(!FindTestHook.pageLine("finished").contains("ready"))
    }
}

/// The Mac side of FindTestHook, read from its source (KiteMac isn't a test target).
struct FindTestHookSourceTests {
    private static let mac = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/KiteMac")

    /// With LF line ends: a Windows checkout (Windows CI runs these too) has CRLF.
    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.mac.appendingPathComponent(path), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// From `signature` to the first line closing a member at four spaces' indent.
    private func body(of signature: String, in source: String) throws -> String {
        let start = try #require(source.range(of: signature), "no \(signature)")
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex), "no end of \(signature)")
        return String(source[start.lowerBound..<end.upperBound])
    }

    @Test func theQueryGoesThroughTheFieldsOwnPath() throws {
        let bar = try source("Views/FindBar.swift")
        // A keystroke: the field's delegate gets controlTextDidChange and runs search().
        #expect(bar.contains("func controlTextDidChange(_ notification: Notification) { search() }"))
        // setQuery: the field's string value, then that same search().
        let setQuery = try body(of: "func setQuery(_ text: String) {", in: bar)
        #expect(setQuery.contains("field.stringValue = text"))
        #expect(setQuery.contains("search()"))
        let apply = try body(of: "func applyFindTestHook(_ hook: FindTestHook, fallback: Bool = false) -> Bool {", in: try source("BrowserWindowController+PageCommands.swift"))
        #expect(apply.contains("bar.setQuery(text)"))
        // ⌘F's own path (showFind is openFind with the saved Ask on Page setting), with the step's Ask on Page.
        #expect(apply.contains("openFind(askEnabled: askOnPage)"))
    }

    @Test func theHookedBarIgnoresTheSavedAskOnPageSetting() throws {
        let commands = try source("BrowserWindowController+PageCommands.swift")
        let apply = try body(of: "func applyFindTestHook(_ hook: FindTestHook, fallback: Bool = false) -> Bool {", in: commands)
        let openFind = try body(of: "private func openFind(askEnabled: Bool) {", in: commands)
        #expect(!apply.contains("AskOnPage.isEnabled"))
        #expect(!apply.contains("showFind(nil)"))   // the saved setting's path (its Step is still .showFind(askOnPage:))
        #expect(!openFind.contains("AskOnPage.isEnabled"))
        #expect(openFind.contains("bar.askEnabled = askEnabled"))
        #expect(try body(of: "@objc func showFind(_ sender: Any?) {", in: commands)
            .contains("openFind(askEnabled: AskOnPage.isEnabled(in: .standard))"))
    }

    @Test func nothingFromTheQueryReachesAsk() throws {
        let bar = try source("Views/FindBar.swift")
        let path = try ["func setQuery(_ text: String) {", "private func search() {", "func step(forward: Bool) {"]
            .map { try body(of: $0, in: bar) }
        // setQuery → search → step → onSearch (the page's find): never submit or onAsk (which asks Claude).
        for code in path {
            for banned in ["submit", "onAsk", "isAskMode"] {
                #expect(!code.contains(banned), "\(banned) in \(code.prefix(40))")
            }
        }
        // submit() has two callers: Return in the field (insertNewline), which the hook never sends, and the ask
        // card's Ask button, hidden unless the bar is the ask card in ask mode.
        #expect(bar.components(separatedBy: "submit()").count - 1 == 3)   // its declaration and those two calls
        let command = try body(of: "func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {", in: bar)
        let newline = try #require(command.range(of: "case #selector(NSResponder.insertNewline(_:)):"))
        let cancel = try #require(command.range(of: "case #selector(NSResponder.cancelOperation(_:)):"))
        #expect(command[newline.upperBound..<cancel.lowerBound].contains("submit()"))
        #expect(bar.contains("askButton = AskPillButton { [weak self] in self?.submit() }"))
        #expect(try body(of: "private func updateAskButton() {", in: bar).contains("askButton.isHidden = !(style == .ask && isAskMode)"))
        // onAsk runs only from submit(), and only in ask mode, which needs Ask on Page on: the hooked bar never is.
        #expect(bar.components(separatedBy: "onAsk?(").count - 1 == 1)
        #expect(try body(of: "private func submit() {", in: bar).contains("if isAskMode, !question.isEmpty { onAsk?(question) }"))
        #expect(bar.contains("AskOnPage.isAskMode(enabled: askEnabled,"))
        for query in ["", "zqxj", "domain"] {
            for matches in [nil, 0, 2] as [Int?] {
                for inConversation in [false, true] {
                    #expect(!AskOnPage.isAskMode(enabled: FindTestHook.asksOnPage, query: query, matches: matches,
                                                 inConversation: inConversation))
                }
            }
        }
    }

    @Test func theHookIsTestSafeOnlyAndSendsNoKeys() throws {
        let apply = try body(of: "func applyFindTestHook(_ hook: FindTestHook, fallback: Bool = false) -> Bool {", in: try source("BrowserWindowController+PageCommands.swift"))
        let runner = try source("Diagnostics/FindTestHookRunner.swift")
        #expect(apply.contains("guard WindowPresenter.testSafe"))
        let start = try body(of: "static func start(", in: runner)
        #expect(start.contains("guard WindowPresenter.testSafe else { return }"))
        #expect(start.contains("FindTestHook.from(environment: environment, testSafe: WindowPresenter.testSafe)"))
        // Everything the hook runs: its own code, ⌘F's open and the bar's focus, setQuery, search and step.
        let commands = try source("BrowserWindowController+PageCommands.swift")
        let bar = try source("Views/FindBar.swift")
        let reached = try [body(of: "private func openFind(askEnabled: Bool) {", in: commands),
                           body(of: "@objc func showFind(_ sender: Any?) {", in: commands),
                           body(of: "func focus() {", in: bar), body(of: "func setQuery(_ text: String) {", in: bar),
                           body(of: "private func search() {", in: bar), body(of: "func step(forward: Bool) {", in: bar),
                           body(of: "func reveal() {", in: bar)]
        // No key events (they go through the input method), no typing into a field editor, nothing fronted.
        for code in [apply, runner] + reached {
            for banned in ["insertText", "keyEvent", "CGEvent", "sendEvent", "postEvent", "keyDown", "makeKey",
                           "orderFront", "activate", "insertNewline", "performKeyEquivalent", "runModal"] {
                #expect(!code.contains(banned), "\(banned)")
            }
        }
        #expect(try source("AppDelegate.swift").contains("FindTestHookRunner.start(in: windowController)"))
    }

    @Test func aFindHooksPageAnswersBehindOtherWindowsOnTestSafeRunsOnly() throws {
        // The cause of W21's first headless run: the covered test window's page never finished loading.
        let webKit = try source("Engine/WebKitEngine.swift")
        #expect(webKit.contains("if PageContextMenuItems.testMode != nil || FindTestHookRunner.configured != nil, webView.responds(to: setOcclusion) {"))
        let runner = try source("Diagnostics/FindTestHookRunner.swift")
        let declaration = try #require(runner.range(of: "nonisolated static let configured = "))
        let configured = runner[declaration.upperBound...].prefix { $0 != ")" }
        #expect(configured.hasPrefix("FindTestHook.from(environment: ProcessInfo.processInfo.environment,"))
        #expect(configured.hasSuffix("testSafe: WindowPresenter.testSafe"))
        // Armed and timed-out lines, so a run that doesn't open the bar says why.
        #expect(try body(of: "static func start(", in: runner).contains("log(FindTestHook.armedLine("))
        #expect(try body(of: "private func poll(until deadline: Date) {", in: runner).contains("Self.log(FindTestHook.timeoutLine(wait))"))
    }

    @Test func aPageThatNeverLoadsStillGetsTheBarAndSaysWhereTheLoadStopped() throws {
        let runner = try source("Diagnostics/FindTestHookRunner.swift")
        let poll = try body(of: "private func poll(until deadline: Date) {", in: runner)
        // The same hook (test-safe, no keys), marked as a fallback, and its own ready line only when the bar is open.
        #expect(poll.contains("if controller.applyFindTestHook(hook, fallback: true) { Self.log(FindTestHook.fallbackLine(hook)) }"))
        // Page milestones are logged only on a run with a find hook.
        #expect(try body(of: "static func logPage(", in: runner).contains("guard configured != nil else { return }"))
        let webKit = try source("Engine/WebKitEngine.swift")
        for milestone in ["\"started\"", "\"committed\"", "\"finished\"", "\"failed before commit\", error: error",
                          "\"failed\", error: error", "\"content process ended\""] {
            #expect(webKit.contains("FindTestHookRunner.logPage(\(milestone))"), "\(milestone)")
        }
        // The fallback doesn't also write the normal ready line for an empty bar.
        let apply = try body(of: "func applyFindTestHook(_ hook: FindTestHook, fallback: Bool = false) -> Bool {",
                             in: try source("BrowserWindowController+PageCommands.swift"))
        #expect(apply.contains("if hook == .open, open, !fallback { FindTestHookRunner.log(FindTestHook.openLine) }"))
    }

    @Test func aFallbackQueryWritesNoResultLine() throws {
        // A result line after the fallback's would contradict it: the fallback only puts the text in the field.
        let commands = try source("BrowserWindowController+PageCommands.swift")
        let apply = try body(of: "func applyFindTestHook(_ hook: FindTestHook, fallback: Bool = false) -> Bool {", in: commands)
        #expect(apply.contains("for step in hook.steps(fallback: fallback) {"))
        let textOnly = try #require(apply.range(of: "case .setTextOnly(let text):"))
        let fallbackCase = apply[textOnly.upperBound...]
        #expect(fallbackCase.contains("bar.setTextWithoutSearching(text)"))
        for banned in ["onResult", "setQuery(", "resultLine", "search(", "step(", "onSearch"] {
            #expect(!fallbackCase.contains(banned), "\(banned)")
        }
        // The one place results are logged is the searching step's callback, before the fallback's case.
        #expect(apply.components(separatedBy: "FindTestHook.resultLine(").count - 1 == 1)
        let searching = try #require(apply.range(of: "case .setQuery(let text):"))
        let logged = try #require(apply.range(of: "FindTestHook.resultLine("))
        #expect(searching.upperBound <= logged.lowerBound && logged.upperBound <= textOnly.lowerBound)
        // setTextWithoutSearching sets the text only: no search, no find, nothing reported.
        let bar = try source("Views/FindBar.swift")
        let textWithoutSearching = try body(of: "func setTextWithoutSearching(_ text: String) {", in: bar)
        #expect(textWithoutSearching.contains("field.stringValue = text"))
        for banned in ["search()", "step(", "onSearch", "onResult", "show("] {
            #expect(!textWithoutSearching.contains(banned), "\(banned)")
        }
        // And the bar's only result report is show(_:)'s, which only the page's find completion calls.
        #expect(bar.components(separatedBy: "onResult?(").count - 1 == 1)
        #expect(try body(of: "func show(_ result: FindResult) {", in: bar).contains("onResult?(result, countLabel.stringValue)"))
    }

    @Test func kitesFallbackComesInsideTheScriptsWait() throws {
        // The script waits FIND_READY_SECONDS once Kite's socket answers (a few seconds after launch); Kite's timer
        // starts at launch, so its fallback line must come with room to spare.
        let script = try String(contentsOf: Self.mac.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/mac-reference-captures.sh"), encoding: .utf8)
        let line = try #require(script.split(whereSeparator: \.isNewline).first { $0.hasPrefix("FIND_READY_SECONDS=") })
        let seconds = try #require(Double(line.dropFirst("FIND_READY_SECONDS=".count)))
        #expect(FindTestHook.pageLoadTimeout + 5 <= seconds)
    }

    @Test func aLoadIsLoggedOnFindHookRunsOnlyAndStillLoads() throws {
        let webKit = try source("Engine/WebKitEngine.swift")
        #expect(webKit.contains("""
                func load(_ url: URL) {
                    webView.load(URLRequest(url: url))
                    FindTestHookRunner.logLoadAsked(webView)
            """))
        let runner = try source("Diagnostics/FindTestHookRunner.swift")
        #expect(try body(of: "static func logLoadAsked(_ webView: WKWebView) {", in: runner).hasPrefix(
            "static func logLoadAsked(_ webView: WKWebView) {\n        guard configured != nil else { return }"))
        #expect(try body(of: "private func poll(until deadline: Date) {", in: runner)
            .contains("wait.contentProcess = Self.contentProcess(of: webView)"))
    }
}
