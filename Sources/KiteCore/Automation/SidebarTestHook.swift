import Foundation

/// The sidebar's popover and page states for headless reference captures (scripts/mac-reference-captures.sh), which can't
/// click what opens them: the space menu's Change Space Icon… is in a real menu, and + › New Space and Choose a Theme
/// are a SymbolButton and a SwiftUI button, none of them a view the script may click.
///
/// - `KITE_TEST_ICON_PICKER=name`: Change Space Icon…'s picker open for the space named exactly `name`, as the space
///   menu opens it (`BrowserStore.requestIconPicker`), on the tab its icon came from.
/// - `KITE_TEST_NEW_SPACE=1`: + › New Space (`BrowserStore.beginNewSpace`): Arc's Create a Space page for a new draft.
///   With `KITE_TEST_NEW_SPACE_NAME=text`, its name field holds `text` (set as its binding's value, not typed: no key
///   events, so no input method). With `KITE_TEST_NEW_SPACE_THEME=n` (1…7), the theme editor's preset `n` is picked
///   for the draft as its swatch picks it (the intensity kept), and the theme editor is open from Choose a Theme, as
///   a press on the row opens it.
///
/// Only on a test-safe run (`WindowPresentation.isTestSafe`); a real profile ignores them all. Exact values only: a
/// flag is exactly `1`, a preset one of `1`…`7`, a name or text one short line (FindTestHook's rule); anything else
/// turns the hook off, as does the picker's hook beside the page's. Nothing is pressed, typed, activated or fronted:
/// the popovers open from the views they hang from, in Kite's own window. Once the state is up the runner writes a
/// `KITE_TEST_SIDEBAR: ready: …` line on stderr, which the capture script waits for: it starts with whether Kite is
/// the active app and where the popover went (`Shown`), and the script fails the state unless Kite isn't active and
/// the popover, if any, is a child of the main window. If the state then goes (a transient popover closes, the page
/// ends) or Kite becomes active, the runner writes `KITE_TEST_SIDEBAR: changed: …`, and the script drops the capture.
public enum SidebarTestHook: Equatable, Sendable {
    /// `KITE_TEST_ICON_PICKER`: the picker for the space with this name.
    case iconPicker(space: String)
    /// `KITE_TEST_NEW_SPACE=1`: Create a Space, its name field holding `name`, and with `preset` (0-based, in
    /// `Theme.presets`) that preset picked and the theme editor open.
    case newSpace(name: String?, preset: Int?)

    public static let iconPickerKey = "KITE_TEST_ICON_PICKER"
    public static let newSpaceKey = "KITE_TEST_NEW_SPACE"
    public static let newSpaceNameKey = "KITE_TEST_NEW_SPACE_NAME"
    public static let newSpaceThemeKey = "KITE_TEST_NEW_SPACE_THEME"
    public static let keys = [iconPickerKey, newSpaceKey, newSpaceNameKey, newSpaceThemeKey]
    /// The stderr prefix of every line the hook writes.
    public static let logPrefix = "KITE_TEST_SIDEBAR:"
    /// How long the runner waits for a popover to show before it says it didn't. Under the capture script's
    /// SIDEBAR_READY_SECONDS, which only starts once Kite's socket answers.
    public static let readyTimeout: Double = 10

    /// The hook to run, or nil: off unless `testSafe`, and off for any value that isn't exact.
    public static func from(environment: [String: String], testSafe: Bool) -> SidebarTestHook? {
        guard testSafe else { return nil }
        let picker = environment[iconPickerKey]
        let newSpace = environment[newSpaceKey]
        let name = environment[newSpaceNameKey]
        let theme = environment[newSpaceThemeKey]
        if let picker {
            // One state a run: the picker beside the page is no hook at all.
            guard newSpace == nil, name == nil, theme == nil, refusal(picker) == nil else { return nil }
            return .iconPicker(space: picker)
        }
        // The page's values without the page are nothing.
        guard newSpace == "1" else { return nil }
        if let name, refusal(name) != nil { return nil }
        var preset: Int?
        if let theme {
            guard let index = presetIndex(theme) else { return nil }
            preset = index
        }
        return .newSpace(name: name, preset: preset)
    }

    /// Why a test-safe run doesn't take a name or text value, or nil when it does: not empty, and FindTestHook's
    /// rule (one line, at most its length, no control or function-key characters).
    public static func refusal(_ text: String) -> String? {
        if text.isEmpty { return "is empty" }
        return FindTestHook.refusal(text)
    }

    /// `KITE_TEST_NEW_SPACE_THEME`'s preset, 0-based: exactly one of `1`…`7` (Theme.presets' count).
    public static func presetIndex(_ value: String) -> Int? {
        let presets = Theme.presets.indices.map { String($0 + 1) }
        guard let index = presets.firstIndex(of: value) else { return nil }
        return index
    }

    /// The space the picker's hook names: the one space whose name is exactly `name`; none for none or for two.
    public static func space(named name: String, in state: BrowserState) -> UUID? {
        let matches = state.spaces.filter { $0.name == name }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// The draft's theme with the hook's preset picked, as the theme editor's swatch picks it: the preset's colours
    /// and grain, the space's intensity kept.
    public static func theme(_ current: Theme, picking preset: Int) -> Theme {
        var theme = Theme.presets[preset]
        theme.tint = current.tint
        return theme
    }

    /// The stderr line when the runner starts.
    public var armedLine: String { "\(Self.logPrefix) armed: \(description)" }
    /// The stderr line once the state is up, `shown` first, so no name can stand in for it.
    public func readyLine(_ shown: Shown) -> String { "\(Self.logPrefix) ready: \(shown.summary); \(description)" }
    /// The stderr line when the state didn't come up (`why`).
    public func failedLine(_ why: String) -> String { "\(Self.logPrefix) failed: \(description): \(why)" }
    /// The stderr line when the state went after it was ready, or Kite became active (`why`).
    public func changedLine(_ why: String) -> String { "\(Self.logPrefix) changed: \(description): \(why)" }

    /// What the ready line reports about the run: whether Kite is the active app, and the hook's popover's window
    /// (none for Create a Space without a theme).
    public struct Shown: Equatable, Sendable {
        public var appActive: Bool
        public var popover: Popover?

        public struct Popover: Equatable, Sendable {
            /// The popover's window is the key window.
            public var key: Bool
            /// Its window level's raw value.
            public var level: Int
            /// Its window's parent is the main browser window the hook ran in.
            public var parentIsMainWindow: Bool

            public init(key: Bool, level: Int, parentIsMainWindow: Bool) {
                self.key = key
                self.level = level
                self.parentIsMainWindow = parentIsMainWindow
            }
        }

        public init(appActive: Bool, popover: Popover?) {
            self.appActive = appActive
            self.popover = popover
        }

        /// `app active no; popover key no, level 0, parent the main window` (or `; no popover`).
        public var summary: String {
            let popover = popover.map {
                "popover key \($0.key ? "yes" : "no"), level \($0.level), "
                    + "parent \($0.parentIsMainWindow ? "the main window" : "not the main window")"
            } ?? "no popover"
            return "app active \(appActive ? "yes" : "no"); \(popover)"
        }
    }

    /// The stderr line for a set hook a test-safe run doesn't take.
    public static func refusedLine(_ environment: [String: String]) -> String? {
        let set = keys.filter { environment[$0] != nil }
        guard !set.isEmpty else { return nil }
        return "\(logPrefix) refused \(set.joined(separator: ", ")): not exact values (a name or text, NEW_SPACE=1, "
            + "THEME 1-\(Theme.presets.count), and the picker's hook alone)"
    }

    private var description: String {
        switch self {
        case .iconPicker(let space): return "icon picker for \(Self.quote(space))"
        case .newSpace(let name, let preset):
            var parts = ["Create a Space"]
            if let name { parts.append("name \(Self.quote(name))") }
            if let preset { parts.append("preset \(preset + 1), theme editor open") }
            return parts.joined(separator: ", ")
        }
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
