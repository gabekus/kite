import Foundation

/// The right-click menu on View › Show Toolbar's bar: Arc's `commandBarToolbarContextMenuActions`,
/// built by the same function as the sidebar address field's menu (WindowState+CommandBarPlaceholder,
/// called with the placeholder flag off). Order, titles and conditions are from Arc 1.171's binary;
/// see docs/arc-visual-spec.md, "Toolbar right-click menu".
public enum ToolbarMenuItem: Equatable, Sendable {
    /// Arc builds it for every page with a URL, enabled only for a web page.
    case copyURL(enabled: Bool)
    case share
    case capture
    case captureFullPage
    case capturePortraitMode
    case manageExtensions
    /// Shows the whole address (true) or the host only (false): "Show Full URL" / "Hide Full URL".
    case fullURL(show: Bool)
    /// "Show as Toolbar" / "Hide Toolbar".
    case toolbar(show: Bool)
    case separator

    /// Arc's titles. Nil for a separator.
    public var title: String? {
        switch self {
        case .copyURL: "Copy URL"
        case .share: "Share"
        case .capture: "Capture…"
        case .captureFullPage: "Capture Full Page"
        case .capturePortraitMode: "Capture in Portrait Mode"
        case .manageExtensions: "Manage Extensions…"
        case .fullURL(let show): show ? "Show Full URL" : "Hide Full URL"
        case .toolbar(let show): show ? "Show as Toolbar" : "Hide Toolbar"
        case .separator: nil
        }
    }

    public var isEnabled: Bool {
        if case .copyURL(let enabled) = self { return enabled }
        return true
    }
}

public enum ToolbarMenu {
    /// - Parameters:
    ///   - hasURL: the page has an address; Arc shows no menu without one.
    ///   - isWebPage: a web page rather than one of Kite's own pages.
    ///   - extensionsAvailable: extensions run in this window (Arc's Manage Extensions… condition).
    ///   - showsFullURL: Settings' "Show full URL when Toolbar is enabled".
    ///   - showsToolbar: View › Show Toolbar is on (always, for the bar's own menu).
    ///
    /// Arc also has Enable/Disable Shared Quotes last; Kite doesn't have the feature, so it's left out.
    public static func items(hasURL: Bool, isWebPage: Bool, extensionsAvailable: Bool,
                             showsFullURL: Bool, showsToolbar: Bool = true) -> [ToolbarMenuItem] {
        guard hasURL else { return [] }
        var items: [ToolbarMenuItem] = [.copyURL(enabled: isWebPage)]
        if isWebPage { items += [.share, .capture, .captureFullPage, .capturePortraitMode] }
        if extensionsAvailable { items += [.separator, .manageExtensions] }
        var toggles: [ToolbarMenuItem] = []
        if isWebPage { toggles.append(.fullURL(show: !showsFullURL)) }
        toggles.append(.toolbar(show: !showsToolbar))
        return items + [.separator] + toggles
    }
}
