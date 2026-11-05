import Foundation

/// `KITE_TEST_FIND=text` and `KITE_TEST_FIND_OPEN=1`: the find bar (⌘F) for headless reference captures
/// (scripts/mac-reference-captures.sh), which can't send ⌘F (it sends no key but ⌘T) and can't click the bar open
/// (nothing in the window opens it).
///
/// Only on a test-safe run (`WindowPresentation.isTestSafe`); a real profile ignores both. Once the main window's
/// shown page has finished loading, the window opens its find bar as ⌘F does (`showFind`, Ask on Page always off: the
/// plain find bar, with no Ask button), and with `KITE_TEST_FIND`
/// sets the bar's query the way the field takes a keystroke: the field's string value, then the search its
/// text-change delegate runs (`FindBar.setQuery`). No key events, so no input method; nothing is activated, made key,
/// fronted or typed anywhere else, and Return is never pressed (so Ask on Page never asks). When the bar is ready it
/// writes a `KITE_TEST_FIND: ready: …` line on stderr, after the first find result for a query.
public enum FindTestHook: Equatable, Sendable {
    /// `KITE_TEST_FIND_OPEN=1`: the bar open, its field empty.
    case open
    /// `KITE_TEST_FIND=text`: the bar open, searching for `text`.
    case query(String)

    public static let queryKey = "KITE_TEST_FIND"
    public static let openKey = "KITE_TEST_FIND_OPEN"
    /// The stderr prefix of every line the hook writes.
    public static let logPrefix = "KITE_TEST_FIND:"
    /// The longest query taken. The capture script allows far less (its text rule).
    public static let maxQueryLength = 100
    /// How long the hook waits for the shown page to finish loading before it opens the bar anyway. Under the capture
    /// script's FIND_READY_SECONDS (30), which only starts once Kite's socket answers, so the fallback's ready line
    /// comes in time.
    public static let pageLoadTimeout: Double = 20

    /// The hook to run, or nil: off unless `testSafe`, and off for an empty or unacceptable value. A query wins over
    /// `KITE_TEST_FIND_OPEN`.
    public static func from(environment: [String: String], testSafe: Bool) -> FindTestHook? {
        guard testSafe else { return nil }
        if let text = environment[queryKey], !text.isEmpty {
            return refusal(text) == nil ? .query(text) : nil
        }
        return environment[openKey] == "1" ? .open : nil
    }

    /// Why a test-safe run doesn't take `KITE_TEST_FIND`'s value, or nil when it does: one line, at most
    /// `maxQueryLength` characters, no control characters (Return, Tab, Escape…) and none of AppKit's function-key
    /// characters (U+F700–U+F8FF).
    public static func refusal(_ text: String) -> String? {
        if text.count > maxQueryLength { return "longer than \(maxQueryLength) characters" }
        let bad = text.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
                || (0xF700...0xF8FF).contains($0.value)
        }
        return bad ? "holds a control or function-key character" : nil
    }

    /// What the window does, in order.
    public enum Step: Equatable, Sendable {
        /// ⌘F's own action: the bar shown and its field focused (the window's first responder; the window isn't
        /// made key), with Ask on Page on or off whatever the profile's `askOnPageEnabled` says.
        case showFind(askOnPage: Bool)
        /// The field's string value set, then the search its text-change delegate runs on a keystroke.
        case setQuery(String)
        /// The fallback's (the page never loaded): only the field's text, no search, so no find result can come
        /// back and contradict the fallback's ready line.
        case setTextOnly(String)
    }

    /// Ask on Page for the hooked bar: always off. The plain find bar is what the captures show whatever the test
    /// app's saved defaults hold, and its Ask button (which runs Claude) is never there to be reached.
    public static let asksOnPage = false

    public var steps: [Step] { steps(fallback: false) }

    /// `fallback`: the page never loaded, so a query's text goes in without a search.
    public func steps(fallback: Bool) -> [Step] {
        switch self {
        case .open: return [.showFind(askOnPage: Self.asksOnPage)]
        case .query(let text):
            return [.showFind(askOnPage: Self.asksOnPage), fallback ? .setTextOnly(text) : .setQuery(text)]
        }
    }

    /// Whether a finished load is the one to run on: the window's selected tab, its page shown and not loading.
    public static func runs(finishedTab: UUID?, selectedTab: UUID?, pageShown: Bool, pageLoading: Bool) -> Bool {
        guard let finishedTab, finishedTab == selectedTab else { return false }
        return pageShown && !pageLoading
    }

    /// Whether a look at the selected tab (polled, for a load that finished before the hook was armed, or one whose
    /// notification didn't match) finds its page loaded: shown, not loading, and its progress at 1.
    public static func runs(selectedTab: UUID?, pageShown: Bool, pageLoading: Bool?, progress: Double?) -> Bool {
        guard selectedTab != nil, pageShown, pageLoading == false, let progress else { return false }
        return progress >= 1
    }

    /// Whether this run's pages keep answering in a covered window. A test-safe window sits behind the user's
    /// windows, and WebKit stops serving an occluded window's page (its window occlusion detection): the selected
    /// page never finishes loading, so the hook would never run, and a find would never come back. With a find hook
    /// a page's occlusion detection is off, as `KITE_TEST_CONTEXT_MENU` already turns it off. It only keeps the
    /// page drawing and answering behind the other windows; nothing comes to the front.
    public static func keepsCoveredPagesAnswering(environment: [String: String], testSafe: Bool) -> Bool {
        from(environment: environment, testSafe: testSafe) != nil
    }

    /// The stderr line when the hook starts waiting for the page.
    public static func armedLine(_ hook: FindTestHook, coveredPagesAnswer: Bool, windowVisible: Bool) -> String {
        let what: String
        switch hook {
        case .open: what = "open, empty"
        case .query(let text): what = "query \(quote(text))"
        }
        return "\(logPrefix) armed: \(what); waiting up to \(Int(pageLoadTimeout)) s for the selected tab's page to load "
            + "(covered pages answer: \(coveredPagesAnswer ? "yes" : "no"), window visible: \(windowVisible ? "yes" : "no"))"
    }

    /// What the hook saw while it waited, for the line it writes when it gives up.
    public struct Wait: Equatable, Sendable {
        /// Finished-load notifications from the window's pages, and how many were the selected tab's.
        public var loads = 0
        public var selectedLoads = 0
        public var selectedTab = false
        public var pageShown = false
        public var pageLoading: Bool?
        public var progress: Double?
        public var windowVisible = false
        /// The web view's own state (WebKit), read straight from it: the store only hears what the page reports.
        public var webViewLoading: Bool?
        public var webViewProgress: Double?
        public var webViewHasURL: Bool?
        /// Whether the window is ordered in (`isVisible`, covered or not) and on a screen, and how many screens.
        public var windowOrderedIn = false
        public var windowOnScreen = false
        public var screens = 0
        /// Times the page's web content process ended (WebKit reloads it each time).
        public var contentProcessEnds = 0
        /// The page's web content process id: 0 when WebKit has none running for it, nil when it can't be read.
        public var contentProcess: Int?

        public init() {}
    }

    /// How a web content process id reads in the diagnostic lines.
    public static func processText(_ pid: Int?) -> String {
        guard let pid else { return "unknown" }
        return pid > 0 ? "running" : "none"
    }

    /// A page's state when WebKit was asked to load it (`when`: "load asked" straight after, then a later look), on a
    /// run with a find hook: whether the load took (WebKit sets the URL and loading at once) and whether the page
    /// has a web content process. No URL is written.
    public static func loadLine(_ when: String, urlSet: Bool, loading: Bool, progress: Double, contentProcess: Int?) -> String {
        "\(logPrefix) page: \(when) (web view URL set: \(urlSet ? "yes" : "no"), loading: \(loading ? "yes" : "no"), "
            + "progress: \(String(format: "%.2f", progress)), content process: \(processText(contentProcess)))"
    }

    /// The stderr line when no page finished loading in time. The bar opens anyway (`fallbackLine`).
    public static func timeoutLine(_ wait: Wait) -> String {
        func flag(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "unknown" }
        func amount(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "unknown" }
        return "\(logPrefix) no page finished loading in \(Int(pageLoadTimeout)) s, so the find bar opens without it "
            + "(finished loads seen: \(wait.loads), of the selected tab: \(wait.selectedLoads); selected tab: "
            + "\(flag(wait.selectedTab)), page shown: \(flag(wait.pageShown)), loading: \(flag(wait.pageLoading)), "
            + "progress: \(amount(wait.progress)); web view loading: \(flag(wait.webViewLoading)), web view progress: "
            + "\(amount(wait.webViewProgress)), web view URL set: \(flag(wait.webViewHasURL)), content process ended: "
            + "\(wait.contentProcessEnds) times, content process: \(processText(wait.contentProcess)); window visible: "
            + "\(flag(wait.windowVisible)), ordered in: "
            + "\(flag(wait.windowOrderedIn)), on a screen: \(flag(wait.windowOnScreen)), screens: \(wait.screens))"
    }

    /// The ready line when the page never loaded and the bar opened anyway: the capture can go ahead, but a query
    /// shows no result (no counter, no match), which this line and NOTES.md say.
    public static func fallbackLine(_ hook: FindTestHook) -> String {
        switch hook {
        case .open: return "\(logPrefix) ready (fallback, the page never loaded): open, empty"
        case .query(let text): return "\(logPrefix) ready (fallback, the page never loaded): \(quote(text)) set, no find result"
        }
    }

    /// A page milestone, for a run with a find hook (WebKit's navigation delegate): `started`, `committed`,
    /// `finished`, `failed`, `content process ended`. Errors give only their domain and code, never a URL or text.
    public static func pageLine(_ milestone: String, error: (domain: String, code: Int)? = nil) -> String {
        "\(logPrefix) page: \(milestone)" + (error.map { " (\($0.domain) \($0.code))" } ?? "")
    }

    /// The stderr line once the bar is open with an empty field.
    public static var openLine: String { "\(logPrefix) ready: open, empty" }

    /// The stderr line for a find result; `counter` is what the bar shows in the counter's place.
    public static func resultLine(query: String, found: Bool, matches: Int?, activeMatch: Int?, counter: String) -> String {
        var parts = ["\(logPrefix) ready: \(quote(query))", found ? "found" : "not found"]
        if let matches { parts.append("\(matches) matches") }
        if let activeMatch { parts.append("active \(activeMatch)") }
        parts.append("counter \(quote(counter))")
        return parts.joined(separator: ", ")
    }

    /// The stderr line for a value a test-safe run doesn't take.
    public static func refusedLine(_ why: String) -> String { "\(logPrefix) refused \(queryKey): it \(why)" }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
