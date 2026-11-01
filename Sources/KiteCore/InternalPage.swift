import Foundation

/// Kite's own pages. A tab on one of these URLs never loads in the engine; the window draws
/// the page natively over the tab's content area.
public enum InternalPage: String, CaseIterable, Sendable {
    /// Arc's ⌘Y "Opens your History in a new Today tab" (chrome://history there).
    case history
    /// The archive as a tab. Archive › View Archive… now opens the Library's Archive page, as in Arc;
    /// kite://archive still works when typed or restored.
    case archive

    public static let scheme = "kite"

    public init?(_ url: URL?) {
        guard let url, url.scheme?.lowercased() == Self.scheme,
              let page = InternalPage(rawValue: (url.host() ?? "").lowercased()) else { return nil }
        self = page
    }

    public var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    public var title: String {
        switch self {
        case .history: "History"
        case .archive: "Archive"
        }
    }
}
