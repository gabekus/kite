import Foundation

/// The pages of Arc's Library (Window › Open Library… ⇧⌘L), the ones Kite has so far.
///
/// Arc 1.171 names its pages `EaselsAndNotesPage`, `DownloadsPage`, `ArchivePage`, `MediaPage`,
/// `BoostsPage` and `SpacesPage` (`HomePageID`), and remembers the last one shown
/// (`lastSelectedHomePage` in StorableHome.json), which Open Library… opens again. The raw values are
/// Arc's, so the order and a stored value read the same. Kite has no easels, notes or boosts,
/// and the Spaces page is Arc's Space manager, so those are left out until Kite has them.
public enum LibraryPage: String, CaseIterable, Sendable {
    case downloads = "DownloadsPage"
    case archive = "ArchivePage"
    case media = "MediaPage"

    /// The page Open Library… shows before one was ever picked.
    public static let first: LibraryPage = .downloads

    /// The remembered page, or the first one when nothing (or a page Kite doesn't have) is stored.
    public init(stored: String?) {
        self = stored.flatMap(LibraryPage.init(rawValue:)) ?? .first
    }

    public var title: String {
        switch self {
        case .downloads: "Downloads"
        case .archive: "Archive"
        case .media: "Media"
        }
    }
}
