import Foundation

/// Which tab opened which (popups, target=_blank, window.open, ⌘-click), so a tool's result can tell Claude
/// where a click took the work: the new tab comes to the front while Claude would otherwise keep driving the
/// old one. It also spots a page opened again (a second click on a control that opens a popup), so Claude
/// can close the copy. Openers are never closed for Claude: a wizard or sign-in usually comes back to them.
public struct OpenedTabs: Sendable {
    public struct Entry: Hashable, Sendable {
        public var child: UUID
        public var opener: UUID
        public var at: Date
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func record(child: UUID, opener: UUID, at date: Date = Date()) {
        entries.removeAll { $0.child == child }
        entries.append(Entry(child: child, opener: opener, at: date))
    }

    public func opener(of child: UUID) -> UUID? {
        entries.last { $0.child == child }?.opener
    }

    /// Tabs `opener` opened at or after `date`, oldest first.
    public func opened(by opener: UUID, since date: Date) -> [UUID] {
        entries.filter { $0.opener == opener && $0.at >= date }.map(\.child)
    }

    /// An earlier tab from the same opener, still open, showing the same page as `child`.
    public func earlierCopy(of child: UUID, url: (UUID) -> URL?) -> UUID? {
        guard let entry = entries.last(where: { $0.child == child }), let page = url(child).map(Self.page) else { return nil }
        return entries.first { $0.opener == entry.opener && $0.at < entry.at && url($0.child).map(Self.page) == page }?.child
    }

    /// Drops tabs that have closed (as child or opener).
    public mutating func retain(live: Set<UUID>) {
        entries.removeAll { !live.contains($0.child) }
    }

    /// The page a URL shows, for spotting the same page opened twice: no fragment, and case doesn't matter
    /// (sites redirect /AddExisting to /addexisting).
    static func page(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return (components?.string ?? url.absoluteString).lowercased()
    }
}

extension AutomationReport {
    public struct OpenedTab: Hashable, Sendable {
        public var id: UUID
        public var title: String
        public var url: URL?
        public var isFront: Bool
        /// An earlier tab the same opener opened that shows the same page.
        public var copyOf: UUID?

        public init(id: UUID, title: String, url: URL?, isFront: Bool, copyOf: UUID? = nil) {
            self.id = id
            self.title = title
            self.url = url
            self.isFront = isFront
            self.copyOf = copyOf
        }
    }

    /// What to tell Claude when an action on tab `opener` opened tabs. Nil when it opened none.
    public static func opened(_ tabs: [OpenedTab], by opener: UUID) -> String? {
        guard !tabs.isEmpty else { return nil }
        let lines = tabs.map { tab in
            "- tab \(tab.id.uuidString)\(tab.isFront ? " [front]" : "") "
                + AccessibilityOutline.quote(AccessibilityOutline.clean(tab.title, limit: 160)) + " " + (tab.url?.absoluteString ?? "about:blank")
        }
        var text = "This opened \(tabs.count == 1 ? "a new tab" : "\(tabs.count) new tabs") (next to tab \(opener.uuidString)):\n"
            + UntrustedContent.wrap(lines.joined(separator: "\n"), source: "Kite tab list")
        if let front = tabs.last(where: \.isFront) ?? tabs.last {
            text += "\nThe page moved there: pass tab \(front.id.uuidString) to keep working in it."
        }
        for tab in tabs {
            guard let copy = tab.copyOf else { continue }
            text += "\nTab \(tab.id.uuidString) shows the same page as tab \(copy.uuidString), which this tab opened earlier: "
                + "close the one you're not using with tabs_close."
        }
        text += "\nKeep tab \(opener.uuidString) open while its flow goes on: the flow may come back to it. Close a tab it opened once "
            + "that tab's part is done."
        return text
    }
}
