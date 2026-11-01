import Foundation

/// Little Kite: Arc's "Little Arc", a small window for links opened from other apps.
/// The decisions that don't need AppKit live here so they can be tested.
public enum LittleKite {
    /// Kite menu → "Open Links from Other Apps in Little Kite". Arc's key is
    /// `openExternalLinksInLittleBrowserEnabled` (in its defaults key list, Arc 1.171).
    public static let opensExternalLinksKey = "openExternalLinksInLittleKite"

    /// On, like Arc: Arc introduces the behaviour with a "Links Open in Little Arc" NUX on the
    /// first external link, and Gabe's Arc defaults have the key at 1. Arc's registered
    /// default itself wasn't found in its binary (see docs/arc-visual-spec.md).
    public static let opensExternalLinksByDefault = true

    public static func opensExternalLinks(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: opensExternalLinksKey) as? Bool ?? opensExternalLinksByDefault
    }

    /// Where a link from another app opens.
    public enum Destination: Equatable, Sendable {
        case littleKite
        case tab
    }

    /// Web links go to Little Kite while the setting is on. Files (an HTML file opened from
    /// Finder) and anything else still open as a tab in the main window.
    public static func destination(for url: URL, opensExternalLinks: Bool) -> Destination {
        guard opensExternalLinks, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .tab
        }
        return .littleKite
    }

    /// The window's title, as the Window menu lists it: Arc's is "Little Arc — <page title>".
    public static func windowTitle(pageTitle: String?) -> String {
        guard let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Little Kite"
        }
        return "Little Kite — " + title
    }

    /// The page's host as the toolbar shows it, without "www.".
    public static func displayHost(of url: URL?) -> String {
        guard let url else { return "" }
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - URL pill buttons

extension LittleKite {
    /// The trailing buttons in the URL pill, in points from the pill's left edge: Arc 1.171's
    /// extensions button (23×19, shown only while extensions are installed: `hasExtensions`,
    /// `shouldDisplayExtensionsButton`) and the 16pt copy-link button 7.5pt inside the right end.
    /// From `kite probe Arc tree` of a 1784pt Little Arc window: extensions at x 1530.5, copy link
    /// at 1565, so 11.5pt between them (docs/arc-visual-spec.md, "Little Arc").
    public enum Pill {
        public static let copySize = 16.0
        public static let trailingInset = 7.5
        public static let extensionsWidth = 23.0
        public static let extensionsHeight = 19.0
        public static let extensionsGap = 11.5
        /// Room between the host text and the first button (Kite's).
        public static let labelGap = 8.0
    }

    public struct PillButtons: Equatable, Sendable {
        public var copyX: Double
        /// Nil while the extensions button is hidden.
        public var extensionsX: Double?
        /// Where the host text must end.
        public var labelTrailing: Double
    }

    public static func pillButtons(pillWidth: Double, showsExtensions: Bool) -> PillButtons {
        let copyX = pillWidth - Pill.trailingInset - Pill.copySize
        let extensionsX = showsExtensions ? copyX - Pill.extensionsGap - Pill.extensionsWidth : nil
        return PillButtons(copyX: copyX, extensionsX: extensionsX, labelTrailing: (extensionsX ?? copyX) - Pill.labelGap)
    }
}

// MARK: - Downloads tray

extension LittleKite {
    /// Arc's Little Arc downloads tray (`LittleBrowserDownloadsTrayViewController`, Arc 1.171
    /// decomp): a 96pt strip along the window's bottom edge, over the page, holding one 250×56
    /// card per download started in that window, 20pt in from every edge and 10pt apart. Empty
    /// space lets clicks through to the page (its `PassthroughView`). A card's × takes it out of
    /// the tray; the download itself stays in Kite's downloads list.
    public struct DownloadsTray: Equatable, Sendable {
        public static let height = 96.0
        public static let itemWidth = 250.0
        public static let itemHeight = 56.0
        public static let inset = 20.0
        public static let spacing = 10.0

        /// The cards, oldest first.
        public private(set) var ids: [UUID] = []

        public init(ids: [UUID] = []) { self.ids = ids }

        public var isEmpty: Bool { ids.isEmpty }

        /// A download this window started.
        public mutating func add(_ id: UUID) {
            if !ids.contains(id) { ids.append(id) }
        }

        /// The card's ×.
        public mutating func dismiss(_ id: UUID) {
            ids.removeAll { $0 == id }
        }

        /// Drops cards for downloads no longer in the list (Hide from Kite, Clear).
        public mutating func keep(only existing: Set<UUID>) {
            ids.removeAll { !existing.contains($0) }
        }

        /// The card's left edge in the tray's scrolling content.
        public static func itemX(at index: Int) -> Double {
            inset + Double(index) * (itemWidth + spacing)
        }

        /// The scrolling content's width for `count` cards.
        public static func contentWidth(count: Int) -> Double {
            guard count > 0 else { return 0 }
            return itemX(at: count - 1) + itemWidth + inset
        }
    }
}
