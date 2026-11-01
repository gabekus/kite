import Foundation

/// The link section of the web page's right-click menu, as Arc builds it.
///
/// Arc's page menu is Chromium's (RenderViewContextMenu, inside ArcCore) with three items of
/// Arc's own: "Open Link in Split View" and "Open Link in Little Arc" after "Open Link in New
/// Window", and "Capture Image..." after "Save Image As…". Titles, order and separators are
/// read from ArcCore's binary; see docs/arc-visual-spec.md, "Page context menu".
public enum PageContextMenu {
    /// Where an "Open Link in …" item opens the link.
    public enum LinkTarget: String, CaseIterable, Sendable {
        case newTab
        case newWindow
        case splitView
        case littleKite
        case incognitoWindow
    }

    public enum Item: Equatable, Sendable {
        case open(LinkTarget)
        case saveLinkAs
        case copyLinkAddress
        /// Replaces Copy Link Address for a mailto: link (Chromium's IDS_CONTENT_CONTEXT_COPYEMAILADDRESS).
        case copyEmailAddress
        case separator
    }

    /// What the window the page is in can do with a link.
    public struct Host: Equatable, Sendable {
        /// Off in a Little Kite window, which has no split view.
        public var showsSplitView: Bool
        /// False while the focused split already has the most panes.
        public var canAddSplitPane: Bool
        /// Off in Little Kite itself and in incognito windows.
        public var showsLittleKite: Bool
        /// Chromium disables Open Link in Incognito Window in an incognito profile.
        public var isIncognito: Bool

        public init(showsSplitView: Bool = true, canAddSplitPane: Bool = true, showsLittleKite: Bool = true,
                    isIncognito: Bool = false) {
            self.showsSplitView = showsSplitView
            self.canAddSplitPane = canAddSplitPane
            self.showsLittleKite = showsLittleKite
            self.isIncognito = isIncognito
        }

        /// A tab in a Little Kite window.
        public static let littleKite = Host(showsSplitView: false, canAddSplitPane: false, showsLittleKite: false)
    }

    /// The link items, top to bottom, ending with the separator Chromium puts after them.
    public static func linkItems(for url: URL, host: Host) -> [Item] {
        var items: [Item] = [.open(.newTab), .open(.newWindow)]
        if host.showsSplitView { items.append(.open(.splitView)) }
        if host.showsLittleKite { items.append(.open(.littleKite)) }
        items += [
            .open(.incognitoWindow),
            .separator,
            .saveLinkAs,
            url.scheme?.lowercased() == "mailto" ? .copyEmailAddress : .copyLinkAddress,
            .separator,
        ]
        return items
    }

    public static func isEnabled(_ item: Item, host: Host) -> Bool {
        switch item {
        case .open(.splitView): host.canAddSplitPane
        case .open(.incognitoWindow): !host.isIncognito
        default: true
        }
    }

    /// A stable number for an item, for engines that identify menu commands by integer (CEF);
    /// 0 is a separator.
    public static func commandID(_ item: Item) -> Int {
        switch item {
        case .separator: 0
        case .open(let target): 1 + LinkTarget.allCases.firstIndex(of: target)!
        case .saveLinkAs: 20
        case .copyLinkAddress: 21
        case .copyEmailAddress: 22
        }
    }

    public static func item(commandID: Int) -> Item? {
        let all: [Item] = LinkTarget.allCases.map(Item.open) + [.saveLinkAs, .copyLinkAddress, .copyEmailAddress]
        return all.first { self.commandID($0) == commandID }
    }

    /// Arc's titles (Chromium's, without the mnemonic `&`), with Kite for Arc.
    public static func title(_ item: Item) -> String {
        switch item {
        case .open(.newTab): "Open Link in New Tab"
        case .open(.newWindow): "Open Link in New Window"
        case .open(.splitView): "Open Link in Split View"
        case .open(.littleKite): "Open Link in Little Kite"
        case .open(.incognitoWindow): "Open Link in Incognito Window"
        case .saveLinkAs: "Save Link As…"
        case .copyLinkAddress: "Copy Link Address"
        case .copyEmailAddress: "Copy Email Address"
        case .separator: ""
        }
    }

    /// What Copy Link Address / Copy Email Address put on the pasteboard: the address without
    /// "mailto:" for an email link, as Chromium does.
    public static func copiedText(for item: Item, url: URL) -> String {
        guard item == .copyEmailAddress, url.scheme?.lowercased() == "mailto" else { return url.absoluteString }
        let address = url.absoluteString.dropFirst("mailto:".count)
        let bare = address.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return bare.removingPercentEncoding ?? bare
    }

    /// Arc's image items, top to bottom: Chromium's, without Arc's "Capture Image..." (after Save
    /// Image As…), whose action the evidence doesn't show.
    public static let imageTitles = ["Open Image in New Tab", "Save Image As…", "Copy Image", "Copy Image Address"]
}

extension BrowserState {
    /// Open Link in Split View: a new pane after the focused one, showing `url`, focused like
    /// Add Split View's pane.
    @discardableResult
    public mutating func openLinkInSplit(url: URL, id: UUID = UUID(), now: Date = Date()) -> AddSplitResult {
        let result = addSplitPane(id: id, now: now)
        if case .added(let pane) = result { update(tab: pane) { $0.url = url } }
        return result
    }

    /// Whether the focused tab's split (or the tab alone) can take another pane.
    public var canAddSplitPane: Bool {
        selectedTab != nil && (selectedSplit?.tabIDs.count ?? 0) < SplitView.maxPanes
    }
}
