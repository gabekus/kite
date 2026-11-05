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
        #expect(open?.steps == [.showFind])
        let query = FindTestHook.from(environment: testSafe.merging(["KITE_TEST_FIND": "domain"]) { $1 }, testSafe: safe)
        #expect(query == .query("domain"))
        // The bar opens as ⌘F opens it, then the query goes through the field's own path (setQuery), never keys.
        #expect(query?.steps == [.showFind, .setQuery("domain")])
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

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.mac.appendingPathComponent(path), encoding: .utf8)
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
        #expect(apply.contains("showFind(nil)"))
    }

    @Test func theHookIsTestSafeOnlyAndSendsNoKeys() throws {
        let apply = try body(of: "func applyFindTestHook(_ hook: FindTestHook) {", in: try source("BrowserWindowController+PageCommands.swift"))
        let runner = try source("Diagnostics/FindTestHookRunner.swift")
        #expect(apply.contains("guard WindowPresenter.testSafe"))
        let start = try body(of: "static func start(", in: runner)
        #expect(start.contains("guard WindowPresenter.testSafe else { return }"))
        #expect(start.contains("FindTestHook.from(environment: environment, testSafe: WindowPresenter.testSafe)"))
        // No key events (they go through the input method), no typing into a field editor, nothing fronted.
        for code in [apply, runner] {
            for banned in ["insertText", "keyEvent", "CGEvent", "sendEvent", "postEvent", "keyDown", "makeKey",
                           "orderFront", "activate", "insertNewline", "performKeyEquivalent", "runModal"] {
                #expect(!code.contains(banned), "\(banned)")
            }
        }
        #expect(try source("AppDelegate.swift").contains("FindTestHookRunner.start(in: windowController)"))
    }
}
