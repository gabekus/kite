import Foundation

/// The web page's right-click menu, as Arc builds it.
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
        // The page itself (nothing under the pointer).
        case back
        case forward
        case reload
        case savePageAs
        case print
        // An image.
        case openImageInNewTab
        case saveImageAs
        case copyImage
        case copyImageAddress
        // Selected text.
        /// "Look Up “…”" (macOS's dictionary panel).
        case lookUp
        /// "Search Google for “…”", or "Go to …" when the selection is an address.
        case searchSelection
        case copy
        case copyLinkToHighlight
        /// The "Speech" submenu (Start Speaking, Stop Speaking).
        case speech
        case startSpeaking
        case stopSpeaking
        // Developer.
        case viewPageSource
        case inspect
        case separator
    }

    /// Items the browser window runs (they act on the tab as a whole).
    public enum PageCommand: Sendable {
        case savePageAs
        case print
        case viewPageSource
    }

    /// What was right-clicked, as the engine reports it.
    public struct Context: Equatable, Sendable {
        public var linkURL: URL?
        /// The source of the image under the pointer.
        public var imageURL: URL?
        public var selectionText: String
        /// A text field or other editable content: the engine keeps its own menu there.
        public var isEditable: Bool
        public var pageURL: URL?
        public var canGoBack: Bool
        public var canGoForward: Bool
        public var searchEngine: SearchEngine
        /// Whether the system is speaking (enables Stop Speaking).
        public var isSpeaking: Bool

        public init(linkURL: URL? = nil, imageURL: URL? = nil, selectionText: String = "", isEditable: Bool = false,
                    pageURL: URL? = nil, canGoBack: Bool = false, canGoForward: Bool = false,
                    searchEngine: SearchEngine = .google, isSpeaking: Bool = false) {
            self.linkURL = linkURL
            self.imageURL = imageURL
            self.selectionText = selectionText
            self.isEditable = isEditable
            self.pageURL = pageURL
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            self.searchEngine = searchEngine
            self.isSpeaking = isSpeaking
        }

        var hasSelection: Bool { !selectionText.isEmpty }
    }

    /// One row of a built menu: a separator, an item, or a submenu (`children`).
    public struct Entry: Equatable, Sendable {
        public var item: Item
        public var title: String
        public var isEnabled: Bool
        public var children: [Entry]
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
        /// The user's search engine, for the selection's "Search … for".
        public var searchEngine: SearchEngine

        public init(showsSplitView: Bool = true, canAddSplitPane: Bool = true, showsLittleKite: Bool = true,
                    isIncognito: Bool = false, searchEngine: SearchEngine = .google) {
            self.showsSplitView = showsSplitView
            self.canAddSplitPane = canAddSplitPane
            self.showsLittleKite = showsLittleKite
            self.isIncognito = isIncognito
            self.searchEngine = searchEngine
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

    /// Every item that runs something, in a fixed order, for command numbers.
    private static let commandItems: [Item] = LinkTarget.allCases.map(Item.open) + [
        .saveLinkAs, .copyLinkAddress, .copyEmailAddress, .back, .forward, .reload, .savePageAs, .print,
        .openImageInNewTab, .saveImageAs, .copyImage, .copyImageAddress, .lookUp, .searchSelection, .copy,
        .copyLinkToHighlight, .speech, .startSpeaking, .stopSpeaking, .viewPageSource, .inspect,
    ]

    /// A stable number for an item, for engines that identify menu commands by integer (CEF);
    /// 0 is a separator.
    public static func commandID(_ item: Item) -> Int {
        guard item != .separator, let index = commandItems.firstIndex(of: item) else { return 0 }
        return index + 1
    }

    public static func item(commandID: Int) -> Item? {
        commandItems.indices.contains(commandID - 1) ? commandItems[commandID - 1] : nil
    }

    /// Arc's titles (Chromium's, without the mnemonic `&`), with Kite for Arc. Look Up and the
    /// selection search depend on what's selected: see `title(_:context:)`.
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
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload"
        case .savePageAs: "Save As…"
        case .print: "Print…"
        case .openImageInNewTab: "Open Image in New Tab"
        case .saveImageAs: "Save Image As…"
        case .copyImage: "Copy Image"
        case .copyImageAddress: "Copy Image Address"
        case .lookUp: "Look Up"
        case .searchSelection: "Search"
        case .copy: "Copy"
        case .copyLinkToHighlight: "Copy Link to Highlight"
        case .speech: "Speech"
        case .startSpeaking: "Start Speaking"
        case .stopSpeaking: "Stop Speaking"
        case .viewPageSource: "View Page Source"
        case .inspect: "Inspect"
        case .separator: ""
        }
    }

    public static func title(_ item: Item, context: Context) -> String {
        let text = printableSelection(context.selectionText)
        switch item {
        case .lookUp:
            return "Look Up “\(text)”"
        case .searchSelection:
            if URLInput.looksLikeURL(context.selectionText) { return "Go to \(text)" }
            return "Search \(context.searchEngine.displayName) for “\(text)”"
        default:
            return title(item)
        }
    }

    /// Where Search … for / Go to … goes: the selection with its whitespace collapsed, as an
    /// address or a search with the user's engine.
    public static func searchURL(context: Context) -> URL? {
        URLInput.resolve(collapsingWhitespace(context.selectionText), engine: context.searchEngine)
    }

    /// The selection as menu titles show it: whitespace collapsed, at most 50 characters, cut at a
    /// word and ended with "…" when longer (Chromium's PrintableSelectionText: TruncateString to
    /// kMaxSelectionTextLength 50 with WORD_BREAK).
    public static func printableSelection(_ text: String) -> String {
        let collapsed = collapsingWhitespace(text)
        let limit = 50
        guard collapsed.count > limit else { return collapsed }
        var cut = String(collapsed.prefix(limit - 1))
        if let space = cut.lastIndex(of: " "), space > cut.startIndex { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The whole menu for `context`, top to bottom, separators tidied; nil in editable content,
    /// where the engine keeps its own (Undo, Cut, Copy, Paste…).
    ///
    /// Arc's order (ArcCore RenderViewContextMenu::InitMenu 0x4281540, then the macOS
    /// InitToolkitMenu 0x422a654): page items; link items; image items; for a selection Copy,
    /// Copy Link to Highlight, the search item (first in the menu, or after the rest on a link)
    /// and Print…; a separator, View Page Source (page only) and Inspect; then on a selection
    /// Look Up at the top (not on a link) and the Speech submenu at the bottom.
    public static func menu(for context: Context, host: Host) -> [Entry]? {
        guard !context.isEditable else { return nil }
        let isPage = context.linkURL == nil && context.imageURL == nil && !context.hasSelection
        var items: [Item] = []
        if isPage { items += [.back, .forward, .reload, .separator, .savePageAs, .print] }
        if let link = context.linkURL { items += linkItems(for: link, host: host) }
        if context.imageURL != nil {
            if !items.isEmpty { items.append(.separator) }
            items += [.openImageInNewTab, .saveImageAs, .copyImage, .copyImageAddress]
        }
        if context.hasSelection {
            if !items.isEmpty { items.append(.separator) }
            items.append(.copy)
            if ["http", "https"].contains(context.pageURL?.scheme?.lowercased() ?? "") {
                items.append(.copyLinkToHighlight)
            }
            if context.linkURL != nil { items.append(.searchSelection) } else { items.insert(.searchSelection, at: 0) }
            if context.imageURL == nil { items.append(.print) }
        }
        items.append(.separator)
        if isPage { items.append(.viewPageSource) }
        items.append(.inspect)
        if context.hasSelection {
            if context.linkURL == nil { items.insert(contentsOf: [.lookUp, .separator], at: 0) }
            items += [.separator, .speech]
        }
        return tidy(items).map { entry($0, context: context, host: host) }
    }

    private static func entry(_ item: Item, context: Context, host: Host) -> Entry {
        let children = item == .speech ? [Item.startSpeaking, .stopSpeaking].map { entry($0, context: context, host: host) } : []
        return Entry(item: item, title: title(item, context: context),
                     isEnabled: isEnabled(item, context: context, host: host), children: children)
    }

    public static func isEnabled(_ item: Item, context: Context, host: Host) -> Bool {
        switch item {
        case .back: context.canGoBack
        case .forward: context.canGoForward
        case .stopSpeaking: context.isSpeaking
        default: isEnabled(item, host: host)
        }
    }

    /// Drops separators at either end and runs of them in between.
    static func tidy(_ items: [Item]) -> [Item] {
        var result: [Item] = []
        for item in items {
            if item == .separator && (result.last ?? .separator) == .separator { continue }
            result.append(item)
        }
        while result.last == .separator { result.removeLast() }
        return result
    }

    /// What Copy Link Address / Copy Email Address put on the pasteboard: the address without
    /// "mailto:" for an email link, as Chromium does.
    public static func copiedText(for item: Item, url: URL) -> String {
        guard item == .copyEmailAddress, url.scheme?.lowercased() == "mailto" else { return url.absoluteString }
        let address = url.absoluteString.dropFirst("mailto:".count)
        let bare = address.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return bare.removingPercentEncoding ?? bare
    }
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
