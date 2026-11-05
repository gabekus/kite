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
        #expect(!FindTestHook.timeoutLine.contains("ready"))
        #expect(!FindTestHook.refusedLine("x").contains("ready"))
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
        let apply = try body(of: "func applyFindTestHook(_ hook: FindTestHook) {", in: try source("BrowserWindowController+PageCommands.swift"))
        #expect(apply.contains("bar.setQuery(text)"))
        // ⌘F's own path (showFind is openFind with the saved Ask on Page setting), with the step's Ask on Page.
        #expect(apply.contains("openFind(askEnabled: askOnPage)"))
    }

    @Test func theHookedBarIgnoresTheSavedAskOnPageSetting() throws {
        let commands = try source("BrowserWindowController+PageCommands.swift")
        let apply = try body(of: "func applyFindTestHook(_ hook: FindTestHook) {", in: commands)
        let openFind = try body(of: "private func openFind(askEnabled: Bool) {", in: commands)
        #expect(!apply.contains("AskOnPage.isEnabled"))
        #expect(!apply.contains("showFind("))
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
        let apply = try body(of: "func applyFindTestHook(_ hook: FindTestHook) {", in: try source("BrowserWindowController+PageCommands.swift"))
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
}
