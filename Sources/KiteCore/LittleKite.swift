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

// MARK: - Links settings (Settings › Links)

extension LittleKite {
    /// "Open Little Kite when clicking on links with ⌥⌘ held". Arc's key is
    /// `optionCommandClickLittleArcEntryPointEnabled`. On by default: the key is absent from Gabe's
    /// Arc defaults while Arc's Links pane shows the switch on (AX tree, Arc 1.171).
    public static let optionCommandClickKey = "optionCommandClickLittleKiteEnabled"

    /// "Open Little Kite when I press ⌥⌘N in any app". Arc's key is `globalLittleBrowserHotkeyEnabled`,
    /// on by default for the same reason.
    public static let globalHotkeyKey = "globalLittleKiteHotkeyEnabled"

    public static func opensOnOptionCommandClick(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: optionCommandClickKey) as? Bool ?? true
    }

    public static func globalHotkeyEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: globalHotkeyKey) as? Bool ?? true
    }

    /// "Archive Little Kites after:". Arc 1.171 offers only 1, 6 and 12 hours here (the static case list
    /// its `ThresholdPreferenceView` takes for Little Arc; tabs get 12 hours to 30 days), 6 by default.
    /// Arc's key is `autoArchiveLittleArcTimeThreshold`.
    public enum ArchiveThreshold: String, CaseIterable, Sendable {
        case oneHour, sixHours, twelveHours

        public static let key = "autoArchiveLittleKiteTimeThreshold"
        public static let defaultValue = ArchiveThreshold.sixHours

        public static func current(in defaults: UserDefaults) -> ArchiveThreshold {
            defaults.string(forKey: key).flatMap(ArchiveThreshold.init(rawValue:)) ?? defaultValue
        }

        public var seconds: TimeInterval {
            switch self {
            case .oneHour: 3600
            case .sixHours: 6 * 3600
            case .twelveHours: 12 * 3600
            }
        }

        /// Arc's labels; the default one reads "6 hours (default)", as Arc's pop-up does.
        public var title: String {
            let base = switch self {
            case .oneHour: "1 hour"
            case .sixHours: "6 hours"
            case .twelveHours: "12 hours"
            }
            return self == Self.defaultValue ? base + " (default)" : base
        }

        /// A Little Kite window not used since `lastActive` goes once the threshold has passed. One in use
        /// (key in the active app) never does.
        public func isStale(lastActive: Date, inUse: Bool, now: Date = Date()) -> Bool {
            !inUse && now.timeIntervalSince(lastActive) >= seconds
        }
    }
}

// MARK: - Global hotkey

extension LittleKite {
    /// The Carbon virtual key code (US ANSI positions, as `kVK_ANSI_*`) for a menu key equivalent,
    /// so New Little Kite Window's shortcut can be registered as a global hotkey. Nil for keys without one.
    public static func virtualKeyCode(for key: String) -> UInt32? {
        let codes: [String: UInt32] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
            "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
            "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
            "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
            "return": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "escape": 0x35,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        ]
        return codes[key.count == 1 ? key.lowercased() : key]
    }

    /// Carbon modifier bits (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public static func carbonModifiers(_ modifiers: [KeyShortcut.Modifier]) -> UInt32 {
        modifiers.reduce(0) { bits, modifier in
            let bit: UInt32 = switch modifier {
            case .command: 0x0100
            case .shift: 0x0200
            case .option: 0x0800
            case .control: 0x1000
            }
            return bits | bit
        }
    }
}

// MARK: - Profile indicator

extension LittleKite {
    /// Arc's Little Arc toolbar shows the page's profile (`ProfileIndicatorView`, tooltip "an indicator
    /// displaying the current profile") at the pill's leading edge, behind `shouldShowProfileIndicators`.
    /// Kite shows it once there is more than one profile, as Arc's profile pickers do (inferred).
    public static func showsProfileIndicator(profileCount: Int) -> Bool { profileCount > 1 }

    /// The indicator's place in the pill: the 14pt image 14pt in (x 121 in a window whose pill starts at
    /// 107, `kite probe Arc tree`), then the profile's name.
    public enum ProfileIndicator {
        public static let x = 14.0
        public static let imageSize = 14.0
        public static let nameGap = 5.0
        public static let fontSize = 12.0
        /// Room between the name and the host text.
        public static let trailingGap = 8.0
    }
}

// MARK: - Open In menu

extension LittleKite {
    /// The chevron beside "Open in <Space>" shows only while there is somewhere else to go (Arc's toolbar
    /// state `hasAdditionalDestinations`).
    public static func hasAdditionalDestinations(spaceCount: Int) -> Bool { spaceCount > 1 }

    /// Arc's `LittleBrowserMoveMenu`: the searchable "Open In" picker the chevron opens (its state holds
    /// `options`, `primaryKeyboardShortcut`, `results`, `searchQuery`, `highlightedOptionID`; its actions
    /// `didUpdateSearchQuery`, `didHover`, `didSelectNext`, `didSelectPrevious`, `didSelectHighlightedOption`,
    /// `didRequestDismiss`). Sizes from its view code (Arc 1.171 decomp, docs/arc-visual-spec.md): 244pt wide,
    /// a 46pt "Search Spaces…" row, 46pt rows, the list at most 350pt tall before it scrolls.
    public struct MoveMenu: Equatable, Sendable {
        public static let width = 244.0
        public static let searchHeight = 46.0
        public static let rowHeight = 46.0
        public static let maxListHeight = 350.0
        /// The magnifying glass: 14pt semibold, centred in a 26pt frame.
        public static let searchIconSize = 14.0
        public static let searchIconFrame = 26.0
        public static let placeholder = "Search Spaces…"

        public struct Option: Equatable, Sendable, Identifiable {
            public var id: UUID
            public var name: String
            public init(id: UUID, name: String) {
                self.id = id
                self.name = name
            }
        }

        /// Every space, in sidebar order.
        public let options: [Option]
        /// The space "Open in" names; its row shows ⌘O.
        public let primaryID: UUID?
        public private(set) var query = ""
        public private(set) var highlightedID: UUID?

        public init(options: [Option], primaryID: UUID?) {
            self.options = options
            self.primaryID = primaryID
            highlightedID = options.first?.id
        }

        /// The options whose names contain the query (case and accents ignored), in sidebar order.
        public var results: [Option] {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return options }
            return options.filter { $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }

        public var highlighted: Option? { results.first { $0.id == highlightedID } }

        /// Typing in the search field: the first match is highlighted.
        public mutating func updateQuery(_ text: String) {
            query = text
            highlightedID = results.first?.id
        }

        public mutating func hover(_ id: UUID) {
            if results.contains(where: { $0.id == id }) { highlightedID = id }
        }

        /// ↓ and ↑ move the highlight, stopping at the ends.
        public mutating func selectNext() { step(1) }
        public mutating func selectPrevious() { step(-1) }

        private mutating func step(_ delta: Int) {
            let list = results
            guard !list.isEmpty else { return highlightedID = nil }
            guard let index = list.firstIndex(where: { $0.id == highlightedID }) else { return highlightedID = list.first?.id }
            highlightedID = list[min(max(index + delta, 0), list.count - 1)].id
        }

        /// The list's height for `count` rows: 46pt each, scrolling past 350.
        public static func listHeight(count: Int) -> Double {
            min(Double(max(count, 0)) * rowHeight, maxListHeight)
        }

        /// The whole menu: the search row, then the list.
        public var height: Double { Self.searchHeight + Self.listHeight(count: results.count) }
    }
}
