import Foundation

/// Kite's AppleScript dictionary (Resources/Kite.sdef), the platform-free half: Arc 1.171's
/// classes and terms (its Arc.sdef), mapped onto Kite's tabs. The Cocoa scripting objects
/// live in KiteMac/AppleScript.swift. Sources are in docs/arc-visual-spec.md.
public enum AppleScripting {
    /// A tab's `location` property, in Arc's words: "topApp" (Arc's internal name for its
    /// favourites), "pinned" or "unpinned".
    public static func location(_ section: TabSection) -> String {
        switch section {
        case .favorite: "topApp"
        case .pinned: "pinned"
        case .unpinned: "unpinned"
        }
    }

    /// A window's tabs: what its sidebar shows, favourites first, then the current space's
    /// pinned and unpinned tabs (the order ⌘1…⌘9 follow).
    public static func windowTabs(_ state: BrowserState) -> [BrowserTab] {
        state.sidebarTabs(in: state.selectedSpaceIndex)
    }

    /// A space's own tabs, pinned then unpinned.
    public static func spaceTabs(_ space: Space) -> [BrowserTab] {
        space.allTabs
    }

    /// `make new tab with properties {URL:…}` needs a URL with a scheme, as in Arc.
    public static func newTabURL(_ value: Any?) -> URL? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty,
              let url = URL(string: string), url.scheme != nil else { return nil }
        return url
    }

    /// Arc's reply to `make new tab` without a usable URL (a string in its binary).
    public static let invalidNewTabURLMessage = "Please provide a valid URL property for the make new tab command."

    /// `execute` while View › Developer › Allow JavaScript from Apple Events is off. Kite's
    /// wording: Arc's refusal text isn't in its binary's strings.
    public static let javaScriptDisabledMessage =
        "Executing JavaScript through AppleScript is turned off. To turn it on, choose View › Developer › Allow JavaScript from Apple Events."

    /// `execute`'s result is text (Arc.sdef): the script's value as a string, JSON for arrays
    /// and objects, and empty for undefined or null.
    public static func text(fromJavaScriptResult value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let string as String: return string
        case let number as NSNumber:
            // Booleans arrive as NSNumber too, of their own class on Apple platforms.
            if type(of: number) == type(of: NSNumber(value: true)) { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case let value? where JSONSerialization.isValidJSONObject(value):
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        case let value?:
            return String(describing: value)
        }
    }

    /// A window's `mode` at creation: "incognito" or "normal" (Arc.sdef).
    public static func isIncognito(mode: String?, incognito: Bool?) -> Bool {
        if let mode { return mode.lowercased() == "incognito" }
        return incognito ?? false
    }
}
