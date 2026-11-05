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
    /// How long the hook waits for the shown page to finish loading before it gives up.
    public static let pageLoadTimeout: Double = 30

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
    }

    /// Ask on Page for the hooked bar: always off. The plain find bar is what the captures show whatever the test
    /// app's saved defaults hold, and its Ask button (which runs Claude) is never there to be reached.
    public static let asksOnPage = false

    public var steps: [Step] {
        switch self {
        case .open: return [.showFind(askOnPage: Self.asksOnPage)]
        case .query(let text): return [.showFind(askOnPage: Self.asksOnPage), .setQuery(text)]
        }
    }

    /// Whether a finished load is the one to run on: the window's selected tab, its page shown and not loading.
    public static func runs(finishedTab: UUID?, selectedTab: UUID?, pageShown: Bool, pageLoading: Bool) -> Bool {
        guard let finishedTab, finishedTab == selectedTab else { return false }
        return pageShown && !pageLoading
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

    /// The stderr line when no page finished loading in time; the bar stays closed.
    public static var timeoutLine: String {
        "\(logPrefix) no page finished loading in \(Int(pageLoadTimeout)) s, so the find bar wasn't opened"
    }

    /// The stderr line for a value a test-safe run doesn't take.
    public static func refusedLine(_ why: String) -> String { "\(logPrefix) refused \(queryKey): it \(why)" }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
